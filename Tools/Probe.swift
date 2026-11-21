import CoreMedia
import Foundation
import Network
import VideoToolbox

// 아이패드 없이 맥 호스트를 시험하는 클라이언트.
// 사용법: build/probe [--host 127.0.0.1] [--port 52020] --pin 123456 [--mode mirror|extend] [--seconds 5]
// 입력 이벤트는 보내지 않는다 (마우스가 움직이지 않음).

struct Options {
    var host = "127.0.0.1"
    var port = ScreenLink.defaultPort
    var pin = ""
    var mode = SessionMode.mirror
    var seconds = 5.0

    init(_ args: [String]) {
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--host": host = it.next() ?? host
            case "--port": port = UInt16(it.next() ?? "") ?? port
            case "--pin": pin = it.next() ?? ""
            case "--mode": mode = SessionMode(rawValue: it.next() ?? "") ?? mode
            case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
            default: break
            }
        }
    }
}

@main
struct Probe {
    static func main() { run() }

    /// 콜백이 모두 probe 큐에서 돌기 때문에 메인 액터에 묶이지 않게 한다.
    nonisolated static func run() {
        let opts = Options(Array(CommandLine.arguments.dropFirst()))
        let queue = DispatchQueue(label: "probe")
        let conn = MessageConnection(endpoint: .hostPort(host: .init(opts.host), port: .init(rawValue: opts.port)!),
                                     queue: queue)
        let builder = H264SampleBufferBuilder()
        var decoder: VTDecompressionSession?
        var received = 0, keyframes = 0, decoded = 0, bytes = 0
        var ack: HelloAck?
        var finished = false
        let start = Date()

        func finish(_ code: Int32, _ message: String) {
            guard !finished else { return }
            finished = true
            print(message)
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "수신 %d프레임 (키프레임 %d) · 디코딩 %d · 평균 %.1f fps · %.1f Mbps",
                         received, keyframes, decoded, Double(received) / elapsed,
                         Double(bytes * 8) / elapsed / 1_000_000))
            conn.send(Message(.bye))
            queue.asyncAfter(deadline: .now() + 0.2) { exit(code) }
        }

        conn.onStateChange = { state in
            switch state {
            case .ready:
                print("연결됨 → hello 전송 (\(opts.mode.rawValue))")
                conn.send(Message.json(.hello, Hello(deviceName: "Probe", pin: opts.pin, mode: opts.mode,
                                                     pointWidth: 1180, pointHeight: 820, scale: 2)))
            case .failed(let reason): finish(2, "연결 실패: \(reason)")
            case .closed: finish(ack?.accepted == true && decoded > 0 ? 0 : 3, "연결 종료")
            case .connecting: break
            }
        }
        conn.onMessage = { m in
            switch m.type {
            case .helloAck:
                ack = try? m.decodeJSON(HelloAck.self)
                guard let ack, ack.accepted else {
                    return finish(4, "거부됨: \(ack?.reason ?? "알 수 없음")")
                }
                print("수락됨: \(ack.hostName) · \(ack.videoWidth)×\(ack.videoHeight)")
            case .video:
                guard let frame = try? VideoFrame(decoding: m.payload) else { return finish(5, "잘못된 프레임") }
                received += 1
                bytes += m.payload.count
                if frame.isKeyframe { keyframes += 1 }
                guard let sample = try? builder.makeSampleBuffer(from: frame),
                      let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
                if decoder == nil {
                    VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                                 imageBufferAttributes: nil, outputCallback: nil,
                                                 decompressionSessionOut: &decoder)
                }
                guard let decoder else { return }
                VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                    status, _, image, _, _ in
                    if status == noErr, image != nil { queue.async { decoded += 1 } }
                }
            case .bye:
                finish(decoded > 0 ? 0 : 3, "호스트가 연결을 끝냈어요.")
            default:
                break
            }
        }
        conn.start()

        queue.asyncAfter(deadline: .now() + opts.seconds) {
            finish(decoded > 0 ? 0 : 6, decoded > 0 ? "완료" : "시간 안에 디코딩된 프레임이 없어요.")
        }
        dispatchMain()
    }
}
