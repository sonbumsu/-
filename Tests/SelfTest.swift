import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

// Xcode 없이 돌릴 수 있는 자체 테스트. `build/selftest`로 실행한다.

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () throws -> Bool, _ message: String,
           file: String = #file, line: Int = #line) rethrows {
    if try condition() {
        passed += 1
    } else {
        failures += 1
        print("  ✗ \(message) (\((file as NSString).lastPathComponent):\(line))")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  ✗ 예외: \(error)")
    }
}

// MARK: - 프로토콜

func testProtocol() {
    test("메시지 헤더 왕복") {
        let m = Message(.input, payload: Data([1, 2, 3]))
        let encoded = m.encoded()
        check(encoded.count == 8, "길이")
        let (type, length) = try Message.parseHeader(encoded.prefix(5))
        check(type == .input && length == 3, "헤더 해석")
    }
    test("잘못된 헤더 거부") {
        var bad = Data([99, 0, 0, 0, 0])
        check((try? Message.parseHeader(bad)) == nil, "알 수 없는 타입")
        bad = Data([3, 0xFF, 0xFF, 0xFF, 0xFF])
        do { _ = try Message.parseHeader(bad); check(false, "너무 큰 payload") } catch {
            check(error as? ProtocolError == .payloadTooLarge(Int(UInt32.max)), "너무 큰 payload 오류")
        }
    }
    test("Hello/HelloAck JSON 왕복") {
        let hello = Hello(deviceName: "iPad", pin: "123456", mode: .extend, pointWidth: 1366, pointHeight: 1024, scale: 2)
        let decoded = try Message.json(.hello, hello).decodeJSON(Hello.self)
        check(decoded == hello, "Hello")
        let ack = HelloAck(accepted: false, reason: "PIN")
        try check(Message.json(.helloAck, ack).decodeJSON(HelloAck.self) == ack, "HelloAck")
    }
    test("입력 이벤트 왕복") {
        let e = InputEvent(.scroll, x: 0.25, y: 0.75, dx: -3.5, dy: 12)
        let data = e.encoded()
        check(data.count == InputEvent.encodedSize, "크기")
        try check(InputEvent(decoding: data) == e, "값")
        check((try? InputEvent(decoding: data.prefix(5))) == nil, "짧은 데이터 거부")
    }
    test("영상 프레임 왕복") {
        let f = VideoFrame(isKeyframe: true, timestampNs: 123_456_789_012,
                           parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])], data: Data(repeating: 7, count: 1000))
        try check(VideoFrame(decoding: f.encoded()) == f, "키프레임")
        let p = VideoFrame(isKeyframe: false, timestampNs: 1, data: Data([0, 0, 0, 1, 0x41]))
        try check(VideoFrame(decoding: p.encoded()) == p, "일반 프레임")
    }
    test("좌표 변환") {
        let bounds = CGRect(x: 1512, y: -200, width: 1366, height: 1024)
        let a = InputInjector.globalPoint(x: 0, y: 0, in: bounds)
        let b = InputInjector.globalPoint(x: 1, y: 1, in: bounds)
        let c = InputInjector.globalPoint(x: 2, y: -1, in: bounds)
        check(a == CGPoint(x: 1512, y: -200), "왼쪽 위")
        check(b == CGPoint(x: 1512 + 1365, y: -200 + 1023), "오른쪽 아래")
        check(c == CGPoint(x: 1512 + 1365, y: -200), "범위 밖은 잘라냄")
    }
}

// MARK: - 인코딩 → 전송 형식 → 디코딩

func makePixelBuffer(width: Int, height: Int, luma: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
        let size = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
        memset(base, Int32(plane == 0 ? luma : 128), size)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

final class Decoder {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private(set) var decoded = 0
    private(set) var lastSize = CGSize.zero
    private let lock = NSLock()

    func decode(_ sample: CMSampleBuffer) throws {
        let fmt = CMSampleBufferGetFormatDescription(sample)!
        if session == nil || !(format.map { CMFormatDescriptionEqual($0, otherFormatDescription: fmt) } ?? false) {
            if let session { VTDecompressionSessionInvalidate(session) }
            var s: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                                      imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &s)
            guard status == noErr else { throw H264Error.coreMedia(status, "decoder") }
            session = s
            format = fmt
        }
        let status = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            guard let self, status == noErr, let image else { return }
            self.lock.lock()
            self.decoded += 1
            self.lastSize = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            self.lock.unlock()
        }
        guard status == noErr else { throw H264Error.coreMedia(status, "decode") }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
    }
}

func testVideoPipeline() {
    test("H.264 인코딩 → 메시지 → 디코딩") {
        let width = 1280, height = 720
        var frames: [VideoFrame] = []
        let lock = NSLock()
        let encoder = try VideoEncoder(width: width, height: height, fps: 60, bitrate: 6_000_000) { frame in
            lock.lock(); frames.append(frame); lock.unlock()
        }
        for i in 0..<20 {
            let pb = makePixelBuffer(width: width, height: height, luma: UInt8(16 + i * 10))
            encoder.encode(pb, pts: CMTime(value: CMTimeValue(i), timescale: 60), forceKeyframe: i == 10)
        }
        // 인코더가 비동기로 내보낼 때까지 기다린다.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock(); let n = frames.count; lock.unlock()
            if n >= 20 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        encoder.invalidate()

        check(frames.count == 20, "프레임 20개 인코딩 (실제 \(frames.count))")
        guard let first = frames.first else { return }
        check(first.isKeyframe, "첫 프레임은 키프레임")
        check(first.parameterSets.count >= 2, "SPS/PPS 포함")
        check(frames.filter(\.isKeyframe).count >= 2, "강제 키프레임 반영")

        let builder = H264SampleBufferBuilder()
        let decoder = Decoder()
        for frame in frames {
            // 실제 전송처럼 바이트로 바꿨다가 다시 읽는다.
            let wire = frame.message.encoded()
            let (type, length) = try Message.parseHeader(wire.prefix(Message.headerSize))
            check(type == .video && length == wire.count - Message.headerSize, "전송 헤더")
            let received = try VideoFrame(decoding: wire.suffix(from: wire.startIndex + Message.headerSize))
            if let sample = try builder.makeSampleBuffer(from: received) {
                try decoder.decode(sample)
            }
        }
        check(decoder.decoded == 20, "20개 모두 디코딩 (실제 \(decoder.decoded))")
        check(decoder.lastSize == CGSize(width: width, height: height), "해상도 유지 (\(decoder.lastSize))")
        check(builder.videoSize == CGSize(width: width, height: height), "포맷에서 읽은 영상 크기")
    }

    test("키프레임 전에는 샘플을 만들지 않음") {
        let builder = H264SampleBufferBuilder()
        let p = VideoFrame(isKeyframe: false, timestampNs: 0, data: Data([0, 0, 0, 1, 0x41]))
        try check(builder.makeSampleBuffer(from: p) == nil, "nil 반환")
    }
}

// MARK: - 네트워크 연결

func testConnection() {
    test("TCP 메시지 연결 왕복") {
        let queue = DispatchQueue(label: "test.net")
        let listener = try NWListener(using: MessageConnection.parameters())
        var serverConn: MessageConnection?
        var serverReceived: [Message] = []
        var clientReceived: [Message] = []
        let done = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)

        let big = Data((0..<2_000_000).map { UInt8($0 & 0xFF) })
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { nw in
            let c = MessageConnection(connection: nw, queue: queue)
            serverConn = c
            c.onMessage = { m in
                serverReceived.append(m)
                if serverReceived.count == 3 { c.send(Message(.pong, payload: Data("ok".utf8))) }
            }
            c.start()
        }
        listener.start(queue: queue)
        check(ready.wait(timeout: .now() + 3) == .success, "리스너 준비")

        let client = MessageConnection(endpoint: .hostPort(host: "127.0.0.1", port: listener.port!), queue: queue)
        client.onStateChange = { state in
            if state == .ready {
                client.send(Message.json(.hello, Hello(deviceName: "t", pin: "1", mode: .mirror,
                                                       pointWidth: 1, pointHeight: 1, scale: 1)))
                client.send(Message(.requestKeyframe))
                client.send(Message(.video, payload: big))
            }
        }
        client.onMessage = { m in clientReceived.append(m); done.signal() }
        client.start()

        check(done.wait(timeout: .now() + 5) == .success, "응답 받음")
        queue.sync {
            check(serverReceived.map(\.type) == [.hello, .requestKeyframe, .video], "메시지 순서")
            check(serverReceived.last?.payload == big, "2MB payload 그대로 도착")
            check(clientReceived.first == Message(.pong, payload: Data("ok".utf8)), "서버 응답")
            check(client.pendingVideoFrames == 0, "전송 대기 프레임 0")
        }
        client.cancel()
        serverConn?.cancel()
        listener.cancel()
    }
}

@main
struct SelfTest {
    static func main() {
        testProtocol()
        testVideoPipeline()
        testConnection()
        print(failures == 0 ? "\n✅ 통과: \(passed)개" : "\n❌ 실패: \(failures)개 / 통과: \(passed)개")
        exit(failures == 0 ? 0 : 1)
    }
}
