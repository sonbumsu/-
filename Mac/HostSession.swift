import CoreMedia
import CoreVideo
import Foundation
import Network

/// 아이패드 한 대와의 연결 하나. 상태는 모두 `queue`에서만 바꾼다.
final class HostSession: @unchecked Sendable {
    struct Info: Equatable {
        var deviceName: String
        var mode: SessionMode
        var width: Int
        var height: Int
    }

    let queue: DispatchQueue
    private let conn: MessageConnection
    private let pin: String
    private let hostName: String
    private let injector = InputInjector()

    /// 메인 스레드에서 호출된다.
    var onStarted: ((Info) -> Void)?
    var onStats: ((Double, Double) -> Void)?   // (fps, Mbps)
    var onEnded: ((String?) -> Void)?

    /// queue에서만 읽고 쓴다.
    var inputEnabled = true

    private var authenticated = false
    private var ended = false
    private var capturer: ScreenCapturer?
    private var encoder: VideoEncoder?
    private var displayID: CGDirectDisplayID = 0
    private var needsKeyframe = true
    private var lastPixelBuffer: CVPixelBuffer?
    private var retryScheduled = false

    // 메인 스레드에서만 접근
    private var virtualDisplay: VirtualDisplay?

    // 통계
    private var framesSent = 0
    private var bytesSent = 0
    private var statsStart = Date()

    /// 네트워크가 밀려 전송 대기 프레임이 이보다 많으면 새 프레임을 버린다.
    private let maxPendingFrames = 3
    private let fps = 60
    private let maxVideoSide = 3072

    init(connection: NWConnection, pin: String, hostName: String) {
        queue = DispatchQueue(label: "screenlink.session", qos: .userInteractive)
        conn = MessageConnection(connection: connection, queue: queue)
        self.pin = pin
        self.hostName = hostName
    }

    func start() {
        conn.onMessage = { [weak self] in self?.handle($0) }
        conn.onStateChange = { [weak self] state in
            switch state {
            case .failed(let reason): self?.end(reason: reason)
            case .closed: self?.end(reason: nil)
            default: break
            }
        }
        conn.start()
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.authenticated else { return }
            self.end(reason: "인증 시간이 지났어요.")
        }
    }

    /// 아무 스레드에서나 불러도 된다.
    func stop() {
        queue.async { [weak self] in
            guard let self, !self.ended else { return }
            self.conn.send(Message(.bye))
            self.end(reason: nil)
        }
    }

    // MARK: - 메시지 처리

    private func handle(_ message: Message) {
        switch message.type {
        case .hello:
            guard !authenticated else { return }
            do {
                handleHello(try message.decodeJSON(Hello.self))
            } catch {
                reject("잘못된 요청이에요.")
            }
        case .input:
            guard authenticated, inputEnabled, InputInjector.isTrusted,
                  let event = try? InputEvent(decoding: message.payload) else { return }
            injector.handle(event, displayID: displayID)
        case .requestKeyframe:
            guard authenticated else { return }
            needsKeyframe = true
            encodeLastFrameIfNeeded()
        case .ping:
            conn.send(Message(.pong, payload: message.payload))
        case .bye:
            end(reason: nil)
        case .helloAck, .video, .pong:
            break
        }
    }

    private func handleHello(_ hello: Hello) {
        guard hello.protocolVersion == ScreenLink.protocolVersion else {
            return reject("앱 버전이 달라요. 맥과 아이패드 앱을 모두 업데이트해 주세요.")
        }
        guard hello.pin == pin else {
            return reject("PIN이 맞지 않아요.")
        }
        guard hello.pointWidth > 0, hello.pointHeight > 0, hello.scale > 0 else {
            return reject("화면 크기 정보가 잘못됐어요.")
        }
        authenticated = true
        Task { await self.setUp(hello) }
    }

    private func reject(_ reason: String) {
        conn.send(Message.json(.helloAck, HelloAck(accepted: false, reason: reason)))
        // 응답이 전달될 시간을 잠깐 준 뒤 끊는다.
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.end(reason: reason) }
    }

    // MARK: - 세션 준비

    private func setUp(_ hello: Hello) async {
        // 1. 캡처할 디스플레이 정하기 (가상 디스플레이는 메인 스레드에서 만든다)
        let target = await chooseDisplay(for: hello)
        guard let (id, rawWidth, rawHeight) = target, rawWidth > 0, rawHeight > 0 else {
            return queue.async { self.reject(hello.mode == .extend ? "가상 디스플레이를 만들지 못했어요." : "화면 정보를 읽지 못했어요.") }
        }
        let (width, height) = Self.fit(width: rawWidth, height: rawHeight, maxSide: maxVideoSide)
        let fps = min(self.fps, max(15, hello.maxFPS))

        // 2. 인코더와 캡처 준비
        let ready: Bool = await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self.preparePipeline(displayID: id, width: width, height: height, fps: fps))
            }
        }
        guard ready, let capturer = queue.sync(execute: { self.capturer }) else { return }

        // 3. 캡처 시작
        do {
            try await capturer.start(displayID: id, width: width, height: height, fps: fps)
        } catch {
            return queue.async {
                self.conn.send(Message(.bye))
                self.end(reason: "화면 캡처를 시작하지 못했어요. 화면 기록 권한을 확인해 주세요. (\(error.localizedDescription))")
            }
        }

        let info = Info(deviceName: hello.deviceName, mode: hello.mode, width: width, height: height)
        queue.async {
            guard !self.ended else { return }
            self.statsStart = Date()
            DispatchQueue.main.async { self.onStarted?(info) }
        }
    }

    @MainActor
    private func chooseDisplay(for hello: Hello) async -> (CGDirectDisplayID, Int, Int)? {
        switch hello.mode {
        case .extend:
            guard let vd = VirtualDisplay(name: "\(hello.deviceName) (ScreenLink)",
                                          pointWidth: hello.pointWidth, pointHeight: hello.pointHeight,
                                          scale: hello.scale) else { return nil }
            virtualDisplay = vd
            guard let size = await vd.waitUntilReady() else {
                virtualDisplay = nil
                return nil
            }
            return (vd.displayID, size.width, size.height)
        case .mirror:
            let id = CGMainDisplayID()
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            return (id, mode.pixelWidth, mode.pixelHeight)
        }
    }

    /// queue에서 호출한다. 인코더와 캡처 객체를 만들고 수락 응답을 보낸다.
    private func preparePipeline(displayID id: CGDirectDisplayID, width: Int, height: Int, fps: Int) -> Bool {
        guard !ended else { return false }
        do {
            displayID = id
            encoder = try VideoEncoder(
                width: width, height: height, fps: fps,
                bitrate: VideoEncoder.defaultBitrate(width: width, height: height, fps: fps)
            ) { [weak self] frame in
                guard let self else { return }
                self.queue.async { self.send(frame) }
            }
            let capturer = ScreenCapturer(queue: queue) { [weak self] pixelBuffer, pts in
                self?.encode(pixelBuffer, pts: pts)
            }
            capturer.onStop = { [weak self] error in
                guard let self else { return }
                self.queue.async { self.end(reason: "화면 캡처가 멈췄어요: \(error?.localizedDescription ?? "")") }
            }
            self.capturer = capturer
            conn.send(Message.json(.helloAck, HelloAck(
                accepted: true, videoWidth: width, videoHeight: height, hostName: hostName)))
            return true
        } catch {
            reject("영상 인코더를 만들지 못했어요.")
            return false
        }
    }

    /// 긴 변이 maxSide를 넘지 않게 줄이고, 인코더를 위해 짝수로 맞춘다.
    static func fit(width: Int, height: Int, maxSide: Int) -> (Int, Int) {
        let longest = max(width, height)
        let ratio = longest > maxSide ? Double(maxSide) / Double(longest) : 1
        let w = Int(Double(width) * ratio) & ~1
        let h = Int(Double(height) * ratio) & ~1
        return (max(w, 2), max(h, 2))
    }

    // MARK: - 영상

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard !ended, let encoder else { return }
        lastPixelBuffer = pixelBuffer
        if conn.pendingVideoFrames >= maxPendingFrames {
            // 프레임을 버렸으니 다음에 보내는 프레임은 반드시 키프레임이어야 한다.
            needsKeyframe = true
            scheduleRetry()
            return
        }
        encoder.encode(pixelBuffer, pts: pts, forceKeyframe: needsKeyframe)
        needsKeyframe = false
    }

    /// 화면이 멈춰 있으면 새 프레임이 오지 않으므로, 버린 프레임을 나중에 다시 보낸다.
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.encodeLastFrameIfNeeded()
        }
    }

    private func encodeLastFrameIfNeeded() {
        guard needsKeyframe, let pixelBuffer = lastPixelBuffer else { return }
        encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private func send(_ frame: VideoFrame) {
        guard !ended else { return }
        let message = frame.message
        conn.send(message)
        framesSent += 1
        bytesSent += message.payload.count

        let elapsed = Date().timeIntervalSince(statsStart)
        if elapsed >= 1 {
            let fps = Double(framesSent) / elapsed
            let mbps = Double(bytesSent * 8) / elapsed / 1_000_000
            framesSent = 0
            bytesSent = 0
            statsStart = Date()
            DispatchQueue.main.async { self.onStats?(fps, mbps) }
        }
    }

    // MARK: - 정리

    private func end(reason: String?) {
        guard !ended else { return }
        ended = true
        NSLog("ScreenLink: 세션 종료 (%@)", reason ?? "정상 종료")
        conn.cancel()
        encoder?.invalidate()
        encoder = nil
        lastPixelBuffer = nil
        let capturer = self.capturer
        self.capturer = nil
        Task {
            await capturer?.stop()
            await MainActor.run {
                // 가상 디스플레이를 놓으면 macOS가 그 위의 창을 메인 화면으로 옮긴다.
                self.virtualDisplay = nil
                self.onEnded?(reason)
            }
        }
    }
}
