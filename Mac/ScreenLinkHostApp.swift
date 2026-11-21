import AppKit
import SwiftUI

@main
struct ScreenLinkHostApp: App {
    @StateObject private var host = HostController()

    var body: some Scene {
        MenuBarExtra {
            HostMenu(host: host)
        } label: {
            Image(systemName: menuIcon)
        }
    }

    private var menuIcon: String {
        if case .streaming = host.status { return "rectangle.on.rectangle.fill" }
        return "rectangle.on.rectangle"
    }
}

struct HostMenu: View {
    @ObservedObject var host: HostController

    var body: some View {
        Group {
            statusSection
            Divider()
            Text("PIN: \(host.pin)")
            Button("새 PIN 만들기") { host.regeneratePIN() }
            if let port = host.port {
                ForEach(host.localAddresses, id: \.self) { ip in
                    Text("주소: \(ip):\(port)")
                }
            }
            Divider()
            Toggle("아이패드에서 맥 조작 허용", isOn: $host.inputEnabled)
            permissionSection
            Divider()
            Button("종료") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear { host.refreshPermissions() }
    }

    @ViewBuilder private var statusSection: some View {
        switch host.status {
        case .starting:
            Text("준비 중…")
        case .waiting:
            Text("아이패드 연결을 기다리는 중")
        case .streaming(let info):
            Text("연결됨: \(info.deviceName)")
            Text("\(info.mode == .extend ? "서브 모니터" : "미러링") · \(info.width)×\(info.height)")
            if !host.stats.isEmpty { Text(host.stats) }
            Button("연결 끊기") { host.disconnect() }
        case .error(let message):
            Text(message)
        }
        if let message = host.lastMessage {
            Text("마지막 종료 이유: \(message)")
        }
    }

    @ViewBuilder private var permissionSection: some View {
        if !host.screenRecordingGranted {
            Button("⚠️ 화면 기록 권한 허용하기…") { host.requestScreenRecording() }
        }
        if !host.accessibilityGranted {
            Button("⚠️ 손쉬운 사용 권한 허용하기…") { host.requestAccessibility() }
        }
    }
}
