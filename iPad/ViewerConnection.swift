import AVFoundation
import Foundation
import Network

/// 맥과의 연결, 영상 수신/표시, 입력 전송을 맡는다. 상태는 모두 `queue`에서만 바꾼다.
final class ViewerConnection: @unchecked Sendable {
    enum Event: Sendable {
        case accepted(HelloAck)
        case videoSize(CGSize)
        case stats(String)
        case ended(String?)
    }

    private let queue = DispatchQueue(label: "screenlink.viewer", qos: .userInteractive)
    private let conn: MessageConnection
    private let hello: Hello
    private let displayLayer: AVSampleBufferDisplayLayer
    private let onEvent: @Sendable (Event) -> Void

    private let builder = H264SampleBufferBuilder()
    private var accepted = false
    private var ended = false
    private var waitingForKeyframe = true
    private var lastKeyframeRequest: TimeInterval = 0
    private var currentSize = CGSize.zero
    private var pingTimer: DispatchSourceTimer?

    // 통계
    private var frames = 0
    private var bytes = 0
    private var statsStart = Date()
    private var rttMs: Double?

    /// - Parameter onEvent: `queue`에서 호출된다. 받는 쪽에서 메인 스레드로 옮겨야 한다.
    init(endpoint: NWEndpoint, hello: Hello, displayLayer: AVSampleBufferDisplayLayer,
         onEvent: @escaping @Sendable (Event) -> Void) {
        conn = MessageConnection(endpoint: endpoint, queue: queue)
        self.hello = hello
        self.displayLayer = displayLayer
        self.onEvent = onEvent
    }

    func start() {
        conn.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.conn.send(Message.json(.hello, self.hello))
            case .failed(let reason):
                self.end(reason: "연결이 끊겼어요. (\(reason))")
            case .closed:
                self.end(reason: self.accepted ? nil : "맥이 연결을 닫았어요.")
            case .connecting:
                break
            }
        }
        conn.onMessage = { [weak self] in self?.handle($0) }
        conn.start()

        // 맥이 응답하지 않으면 포기한다.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.accepted else { return }
            self.end(reason: "맥이 응답하지 않아요. 같은 Wi‑Fi에 있는지, 맥 앱이 켜져 있는지 확인해 주세요.")
        }
    }

    func send(_ event: InputEvent) {
        queue.async { [weak self] in
            guard let self, self.accepted, !self.ended else { return }
            self.conn.send(event.message)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.ended else { return }
            self.conn.send(Message(.bye))
            // bye가 전달될 시간을 잠깐 준다.
            self.queue.asyncAfter(deadline: .now() + 0.1) { self.end(reason: nil) }
        }
    }

    // MARK: - 메시지

    private func handle(_ message: Message) {
        switch message.type {
        case .helloAck:
            guard let ack = try? message.decodeJSON(HelloAck.self) else {
                return end(reason: "맥의 응답을 이해하지 못했어요.")
            }
            guard ack.accepted else {
                return end(reason: ack.reason ?? "맥이 연결을 거부했어요.")
            }
            accepted = true
            statsStart = Date()
            startPing()
            onEvent(.accepted(ack))
        case .video:
            guard accepted, let frame = try? VideoFrame(decoding: message.payload) else { return }
            frames += 1
            bytes += message.payload.count
            display(frame)
            updateStats()
        case .ping:
            conn.send(Message(.pong, payload: message.payload))
        case .pong:
            // 우리가 보낸 시각을 맥이 그대로 돌려준다 (같은 기기의 시계라서 왕복 시간 계산이 정확하다).
            if message.payload.count == 8 {
                let sent = message.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                rttMs = Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000
            }
        case .bye:
            end(reason: "맥에서 연결을 끊었어요.")
        case .hello, .input, .requestKeyframe:
            break
        }
    }

    // MARK: - 영상 표시

    private func display(_ frame: VideoFrame) {
        let renderer = displayLayer.sampleBufferRenderer

        // 앱이 백그라운드에 다녀왔거나 디코딩에 실패하면 비우고 키프레임부터 다시 받는다.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            waitingForKeyframe = true
        }
        if waitingForKeyframe && !frame.isKeyframe {
            requestKeyframe()
            return
        }

        do {
            guard let sample = try builder.makeSampleBuffer(from: frame) else {
                requestKeyframe()
                return
            }
            waitingForKeyframe = false
            renderer.enqueue(sample)
        } catch {
            waitingForKeyframe = true
            requestKeyframe()
        }

        if let size = builder.videoSize, size != currentSize {
            currentSize = size
            onEvent(.videoSize(size))
        }
    }

    private func requestKeyframe() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeyframeRequest > 0.5 else { return }
        lastKeyframeRequest = now
        conn.send(Message(.requestKeyframe))
    }

    // MARK: - 통계

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var now = DispatchTime.now().uptimeNanoseconds
            self.conn.send(Message(.ping, payload: Data(bytes: &now, count: 8)))
            self.updateStats()
        }
        timer.resume()
        pingTimer = timer
    }

    private func updateStats() {
        let elapsed = Date().timeIntervalSince(statsStart)
        guard elapsed >= 1 else { return }
        var text = String(format: "%.0f fps · %.1f Mbps", Double(frames) / elapsed,
                          Double(bytes * 8) / elapsed / 1_000_000)
        if let rttMs { text += String(format: " · 왕복 %.0f ms", rttMs) }
        frames = 0
        bytes = 0
        statsStart = Date()
        onEvent(.stats(text))
    }

    // MARK: - 정리

    private func end(reason: String?) {
        guard !ended else { return }
        ended = true
        pingTimer?.cancel()
        pingTimer = nil
        conn.cancel()
        onEvent(.ended(reason))
    }
}
