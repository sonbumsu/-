import Foundation
import Network

/// 같은 네트워크에서 ScreenLink 맥을 Bonjour로 찾는다.
@MainActor
final class HostBrowser: ObservableObject {
    struct Host: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var hosts: [Host] = []
    @Published private(set) var problem: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: ScreenLink.bonjourType, domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> Host? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Host(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name < $1.name }
            Task { @MainActor in self?.hosts = hosts }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func restart() {
        browser?.cancel()
        browser = nil
        hosts = []
        start()
    }

    private func stateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            problem = nil
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
                problem = "로컬 네트워크 권한이 꺼져 있어요. 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 ScreenLink를 켜 주세요."
            } else {
                problem = "맥을 찾는 중 문제가 생겼어요: \(error.localizedDescription)"
            }
        default:
            break
        }
    }
}
