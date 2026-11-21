import Foundation
import Network

/// NWConnection 위에서 길이 접두사 메시지를 주고받는 연결.
/// 모든 콜백은 생성할 때 넘긴 `queue`에서 호출된다.
public final class MessageConnection: @unchecked Sendable {
    public enum State: Equatable {
        case connecting
        case ready
        case failed(String)
        case closed
    }

    public let connection: NWConnection
    public let queue: DispatchQueue
    public var onMessage: ((Message) -> Void)?
    public var onStateChange: ((State) -> Void)?

    /// 아직 전송이 끝나지 않은 영상 프레임 수. 네트워크가 느려 쌓이면 프레임을 버리는 데 쓴다.
    public private(set) var pendingVideoFrames = 0
    private var finished = false

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public convenience init(endpoint: NWEndpoint, queue: DispatchQueue) {
        self.init(connection: NWConnection(to: endpoint, using: MessageConnection.parameters()), queue: queue)
    }

    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        return params
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.ready)
                self.receiveHeader()
            case .failed(let error):
                self.finish(.failed(error.localizedDescription))
            case .waiting(let error):
                // 상대가 없거나 네트워크가 막힌 경우. 계속 기다리지 않고 실패로 처리한다.
                self.finish(.failed(error.localizedDescription))
            case .cancelled:
                self.finish(.closed)
            default:
                break
            }
        }
        onStateChange?(.connecting)
        connection.start(queue: queue)
    }

    public func send(_ message: Message) {
        let isVideo = message.type == .video
        if isVideo { pendingVideoFrames += 1 }
        connection.send(content: message.encoded(), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if isVideo { self.pendingVideoFrames -= 1 }
            if let error { self.finish(.failed(error.localizedDescription)) }
        })
    }

    public func cancel() {
        connection.cancel()
    }

    private func finish(_ state: State) {
        guard !finished else { return }
        finished = true
        if state != .closed { connection.cancel() }
        onStateChange?(state)
        onMessage = nil
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: Message.headerSize, maximumLength: Message.headerSize) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let error { return self.finish(.failed(error.localizedDescription)) }
            guard let data, data.count == Message.headerSize else {
                return self.finish(isComplete ? .closed : .failed("짧은 헤더"))
            }
            do {
                let (type, length) = try Message.parseHeader(data)
                if length == 0 {
                    self.onMessage?(Message(type))
                    self.receiveHeader()
                } else {
                    self.receivePayload(type: type, length: length)
                }
            } catch {
                self.finish(.failed("프로토콜 오류: \(error)"))
            }
        }
    }

    private func receivePayload(type: MessageType, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let error { return self.finish(.failed(error.localizedDescription)) }
            guard let data, data.count == length else {
                return self.finish(isComplete ? .closed : .failed("짧은 payload"))
            }
            self.onMessage?(Message(type, payload: data))
            self.receiveHeader()
        }
    }
}
