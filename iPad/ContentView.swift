import Network
import SwiftUI

struct ContentView: View {
    @StateObject private var browser = HostBrowser()
    @StateObject private var session = ViewerSession()

    @State private var selected: ConnectTarget?
    @State private var pending: PendingConnection?
    @State private var manualHost = UserDefaults.standard.string(forKey: "manualHost") ?? ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if browser.hosts.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("같은 Wi‑Fi에서 맥을 찾는 중…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.hosts) { host in
                        Button {
                            selected = ConnectTarget(name: host.name, endpoint: host.endpoint)
                        } label: {
                            Label(host.name, systemImage: "laptopcomputer")
                        }
                    }
                } header: {
                    Text("주변의 맥")
                } footer: {
                    if let problem = browser.problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("맥에서 ScreenLink 앱을 켜 두세요. 메뉴 막대 아이콘에서 PIN을 확인할 수 있어요.")
                    }
                }

                Section {
                    HStack {
                        TextField("예: 192.168.0.10", text: $manualHost)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("연결") { connectManually() }
                            .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("IP 주소로 연결")
                } footer: {
                    Text("자동으로 찾지 못할 때 맥 메뉴 막대에 표시된 주소를 입력하세요. 학교·회사 Wi‑Fi에서 안 되면 아이폰 핫스팟에 두 기기를 함께 연결해 보세요.")
                }
            }
            .navigationTitle("ScreenLink")
            .toolbar {
                Button {
                    browser.restart()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear { browser.start() }
        .sheet(item: $selected, onDismiss: startPendingConnection) { target in
            ConnectSheet(target: target) { pin, mode in
                // 시트가 완전히 닫힌 뒤에 전체 화면을 띄워야 화면 전환이 꼬이지 않는다.
                pending = PendingConnection(target: target, pin: pin, mode: mode)
                selected = nil
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { session.isActive },
            set: { if !$0 { session.disconnect() } }
        )) {
            StreamScreen(session: session)
        }
        .alert("연결이 끝났어요", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private func startPendingConnection() {
        guard let p = pending else { return }
        pending = nil
        session.connect(to: p.target.endpoint, hostName: p.target.name, pin: p.pin, mode: p.mode)
    }

    private func connectManually() {
        var text = manualHost.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(text, forKey: "manualHost")
        var port = ScreenLink.defaultPort
        // "주소:포트" 형식도 받는다.
        if let colon = text.lastIndex(of: ":"), let p = UInt16(text[text.index(after: colon)...]) {
            port = p
            text = String(text[..<colon])
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        selected = ConnectTarget(name: text, endpoint: .hostPort(host: NWEndpoint.Host(text), port: nwPort))
    }
}

struct PendingConnection {
    let target: ConnectTarget
    let pin: String
    let mode: SessionMode
}

struct ConnectTarget: Identifiable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// PIN 입력과 모드 선택
struct ConnectSheet: View {
    let target: ConnectTarget
    let onConnect: (String, SessionMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @AppStorage("mode") private var modeRaw = SessionMode.extend.rawValue
    @FocusState private var pinFocused: Bool

    private var mode: Binding<SessionMode> {
        Binding(get: { SessionMode(rawValue: modeRaw) ?? .extend }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("모드") {
                    Picker("모드", selection: mode) {
                        Text("서브 모니터").tag(SessionMode.extend)
                        Text("미러링").tag(SessionMode.mirror)
                    }
                    .pickerStyle(.segmented)
                    Text(mode.wrappedValue == .extend
                         ? "아이패드가 맥의 두 번째 모니터가 돼요. 맥의 시스템 설정 → 디스플레이에서 위치를 바꿀 수 있어요."
                         : "맥의 메인 화면을 그대로 보여줘요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("6자리 숫자", text: $pin)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .focused($pinFocused)
                        .onChange(of: pin) { _, new in
                            pin = String(new.filter(\.isNumber).prefix(6))
                        }
                } header: {
                    Text("PIN")
                } footer: {
                    Text("맥 메뉴 막대의 ScreenLink 아이콘을 누르면 PIN이 보여요.")
                }
            }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("연결") {
                        UserDefaults.standard.set(pin, forKey: pinKey)
                        onConnect(pin, mode.wrappedValue)
                    }
                    .disabled(pin.count != 6)
                }
            }
            .onAppear {
                pin = UserDefaults.standard.string(forKey: pinKey) ?? ""
                pinFocused = pin.isEmpty
            }
        }
        .presentationDetents([.medium])
    }

    private var pinKey: String { "pin.\(target.name)" }
}

/// 연결 중 전체 화면
struct StreamScreen: View {
    @ObservedObject var session: ViewerSession
    @AppStorage("viewOnly") private var viewOnly = false
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            StreamView(session: session, inputEnabled: !viewOnly) {
                withAnimation { showControls.toggle() }
            }
            .ignoresSafeArea()

            if case .connecting(let name) = session.state {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("\(name)에 연결하는 중…").foregroundStyle(.white)
                    Button("취소") { session.disconnect() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showControls {
                controlBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: session.state) {
            // 연결되면 3초 뒤 컨트롤 막대를 숨긴다.
            guard case .streaming = session.state else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { showControls = false }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if case .streaming(let name) = session.state {
                    Text(name).font(.headline)
                }
                Text(session.stats.isEmpty ? "세 손가락으로 탭하면 이 막대를 숨기거나 보여줘요" : session.stats)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("보기 전용", isOn: $viewOnly)
                .fixedSize()
            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Label("연결 끊기", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}
