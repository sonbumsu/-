import AVFoundation
import Network
import UIKit

/// 화면(SwiftUI)이 보는 연결 상태.
@MainActor
final class ViewerSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting(String)
        case streaming(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var stats = ""
    @Published var errorMessage: String?

    /// 영상을 그리는 레이어. StreamView가 화면에 붙인다.
    let displayLayer = AVSampleBufferDisplayLayer()

    private var connection: ViewerConnection?
    private var connectionID = UUID()

    var isActive: Bool { state != .idle }

    func connect(to endpoint: NWEndpoint, hostName: String, pin: String, mode: SessionMode) {
        connection?.stop()
        connection = nil

        let screen = Self.screenInfo()
        let hello = Hello(deviceName: UIDevice.current.name, pin: pin, mode: mode,
                          pointWidth: Int(screen.size.width), pointHeight: Int(screen.size.height),
                          scale: Double(screen.scale), maxFPS: min(60, screen.maxFPS))

        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        videoSize = .zero
        stats = ""
        errorMessage = nil
        state = .connecting(hostName)

        let id = UUID()
        connectionID = id
        let connection = ViewerConnection(endpoint: endpoint, hello: hello, displayLayer: displayLayer) {
            [weak self] event in
            Task { @MainActor in self?.handle(event, id: id) }
        }
        self.connection = connection
        connection.start()
    }

    func send(_ event: InputEvent) {
        connection?.send(event)
    }

    func disconnect() {
        connection?.stop()
        connection = nil
        connectionID = UUID()
        state = .idle
    }

    private func handle(_ event: ViewerConnection.Event, id: UUID) {
        // 이미 끊은 연결에서 늦게 온 이벤트는 무시한다.
        guard id == connectionID else { return }
        switch event {
        case .accepted(let ack):
            state = .streaming(ack.hostName)
            if videoSize == .zero {
                videoSize = CGSize(width: ack.videoWidth, height: ack.videoHeight)
            }
        case .videoSize(let size):
            videoSize = size
        case .stats(let text):
            stats = text
        case .ended(let reason):
            connection = nil
            state = .idle
            errorMessage = reason
        }
    }

    /// 현재 앱 창 크기 (Stage Manager로 창을 줄였으면 그 크기)
    private static func screenInfo() -> (size: CGSize, scale: CGFloat, maxFPS: Int) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return (CGSize(width: 1024, height: 768), 2, 60) }
        let size = scene.keyWindow?.bounds.size ?? scene.screen.bounds.size
        return (size, scene.screen.scale, scene.screen.maximumFramesPerSecond)
    }
}
