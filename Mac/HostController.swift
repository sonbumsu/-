import CoreGraphics
import Foundation
import Network

/// 메뉴 막대 UI가 보는 상태와 Bonjour 리스너를 관리한다.
@MainActor
final class HostController: ObservableObject {
    enum Status: Equatable {
        case starting
        case waiting
        case streaming(HostSession.Info)
        case error(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var pin: String
    @Published private(set) var stats = ""
    @Published private(set) var lastMessage: String?
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibilityGranted = InputInjector.isTrusted
    @Published private(set) var port: UInt16?
    @Published var inputEnabled = true {
        didSet {
            let enabled = inputEnabled
            if let session { session.queue.async { session.inputEnabled = enabled } }
        }
    }

    let hostName = Host.current().localizedName ?? "Mac"
    private var listener: NWListener?
    private var session: HostSession?
    private let listenerQueue = DispatchQueue(label: "screenlink.listener")

    init() {
        let saved = UserDefaults.standard.string(forKey: "pin")
        pin = saved ?? Self.makePIN()
        UserDefaults.standard.set(pin, forKey: "pin")
        // 메뉴를 열기 전에도 바로 연결을 받을 수 있게 앱이 뜨자마자 시작한다.
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    static func makePIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    var localAddresses: [String] { NetworkInfo.ipv4Addresses() }

    // MARK: - 리스너

    func start() {
        guard listener == nil else { return }
        let listener: NWListener
        do {
            let port = NWEndpoint.Port(rawValue: ScreenLink.defaultPort)!
            listener = try NWListener(using: MessageConnection.parameters(), on: port)
        } catch {
            // 기본 포트를 쓸 수 없으면 아무 포트나 쓴다. (Bonjour로는 계속 찾을 수 있다)
            guard let any = try? NWListener(using: MessageConnection.parameters()) else {
                status = .error("연결 대기를 시작하지 못했어요: \(error.localizedDescription)")
                return
            }
            listener = any
        }
        listener.service = NWListener.Service(name: hostName, type: ScreenLink.bonjourType)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerStateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: listenerQueue)
        self.listener = listener
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            if session == nil { status = .waiting }
        case .failed(let error):
            status = .error("연결 대기 중 오류: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
            // 잠시 후 다시 시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard session == nil else {
            // v1은 한 번에 한 대만 연결한다.
            connection.cancel()
            return
        }
        let session = HostSession(connection: connection, pin: pin, hostName: hostName)
        let enabled = inputEnabled
        session.queue.async { session.inputEnabled = enabled }
        session.onStarted = { [weak self] info in
            self?.status = .streaming(info)
            self?.lastMessage = nil
        }
        session.onStats = { [weak self] fps, mbps in
            self?.stats = String(format: "%.0f fps · %.1f Mbps", fps, mbps)
        }
        session.onEnded = { [weak self, weak session] reason in
            guard let self, let session, self.session === session else { return }
            self.session = nil
            self.stats = ""
            self.lastMessage = reason
            self.status = self.listener == nil ? .starting : .waiting
        }
        self.session = session
        session.start()
    }

    // MARK: - 메뉴 동작

    func disconnect() {
        session?.stop()
    }

    func regeneratePIN() {
        pin = Self.makePIN()
        UserDefaults.standard.set(pin, forKey: "pin")
    }

    func refreshPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = InputInjector.isTrusted
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    func requestAccessibility() {
        InputInjector.requestTrust()
        refreshPermissions()
    }
}

enum NetworkInfo {
    /// Wi‑Fi/이더넷의 IPv4 주소 (IP 직접 입력 안내용)
    static func ipv4Addresses() -> [String] {
        var result: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}
