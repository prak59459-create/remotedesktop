import SwiftUI

struct ConnectView: View {
    @ObservedObject var session: ViewerSession

    enum Mode: String, CaseIterable, Identifiable {
        case lan = "同じ Wi-Fi"
        case relay = "外出先 (中継)"
        var id: String { rawValue }
    }

    @AppStorage("mode") private var modeRaw = Mode.lan.rawValue
    @AppStorage("lanHost") private var lanHost = ""
    @AppStorage("lanPort") private var lanPort = "5999"
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage("relayTransport") private var relayTransportRaw = RelayTransportMode.auto.rawValue
    @AppStorage("lanService") private var lanService = "" // Bonjour で見つけて選んだ PC の名前
    @AppStorage("hostName") private var hostName = ""
    @AppStorage("lastConnected") private var lastConnected: Double = 0
    @StateObject private var finder = HostFinder()
    @State private var pairingCode = ""
    @State private var showSettings = false
    @State private var showAbout = false
    @FocusState private var focused: Bool

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .lan }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    hero
                    if let fp = ViewerSession.savedHostFingerprint { pairedCard(fp) }
                    modeCard
                    if mode == .lan { lanCards } else { relayCard }
                    connectButton
                    securityBadges
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showSettings) { SettingsView(session: session) }
        .sheet(isPresented: $showAbout) { AboutView() }
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        #if RD_SCREENSHOTS
        .onReceive(ScreenshotDriver.shared.pairingCode) { pairingCode = $0 }
        .onReceive(ScreenshotDriver.shared.pressConnect) { connect() }
        .onReceive(ScreenshotDriver.shared.showSettings) { showSettings = $0 }
        .onReceive(ScreenshotDriver.shared.showAbout) { showAbout = $0 }
        #endif
    }

    // MARK: 見出し

    private var header: some View {
        HStack {
            Spacer()
            Button { showAbout = true } label: {
                Image(systemName: "info.circle").font(.title3)
            }
            .accessibilityLabel("このアプリについて")
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3)
            }
            .accessibilityLabel("設定")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.top, 12)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: Theme.blue.opacity(0.45), radius: 24, y: 12)
            Text("Remote Desktop")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand)
            Text("Windows を、この iPad から。通信はすべて端末間で暗号化されます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 6)
    }

    // MARK: ペアリング済みの PC

    private func pairedCard(_ fp: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(hostName.isEmpty ? "ペアリング済みの PC" : hostName).font(.headline)
                    StatusPill(text: "ペアリング済み", color: .green)
                }
                Text(fp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if lastConnected > 0 {
                    Text("最後の接続: \(relativeJapanese(Date(timeIntervalSince1970: lastConnected)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    // MARK: 接続方法

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "接続方法", systemImage: "point.3.connected.trianglepath.dotted")
            HStack(spacing: 12) {
                ChoiceCard(title: "同じ Wi-Fi", subtitle: "家や職場で、PC と同じネットワークから",
                           systemImage: "wifi", selected: mode == .lan) { withAnimation { modeRaw = Mode.lan.rawValue } }
                ChoiceCard(title: "外出先から", subtitle: "中継サーバー経由。ポート開放は不要",
                           systemImage: "globe.asia.australia.fill", selected: mode == .relay) {
                    withAnimation { modeRaw = Mode.relay.rawValue }
                }
            }
        }
        .card()
    }

    private var lanCards: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardHeader(title: "この Wi-Fi で見つかった PC", systemImage: "dot.radiowaves.left.and.right", tint: Theme.cyan)
                    StatusPill(text: finder.hosts.isEmpty ? "探しています" : "\(finder.hosts.count) 台", color: Theme.blue,
                               pulsing: finder.hosts.isEmpty)
                }
                if finder.hosts.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("RDHost を起動した PC が自動で表示されます。出てこないときは、PC のネットワークを「プライベート」にするか、下に IP アドレスを入力してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(finder.hosts, id: \.self) { name in
                    Button {
                        lanService = name
                        lanHost = ""
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "pc")
                                .font(.title3)
                                .foregroundStyle(Theme.blue)
                                .frame(width: 40, height: 40)
                                .background(Theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: lanService == name ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(lanService == name ? Theme.blue : Color.secondary.opacity(0.5))
                        }
                        .padding(10)
                        .background(lanService == name ? Theme.blue.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "IP アドレスで指定", systemImage: "number", tint: Theme.indigo)
                HStack(spacing: 10) {
                    FieldRow(systemImage: "network") {
                        TextField("192.168.0.10", text: $lanHost)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    FieldRow(systemImage: "door.left.hand.open") {
                        TextField("5999", text: $lanPort).keyboardType(.numberPad)
                    }
                    .frame(width: 130)
                }
                Text("RDHost の画面に表示される IP アドレス").font(.caption).foregroundStyle(.secondary)
            }
            .card()
            .onChange(of: lanHost) { v in
                if !v.isEmpty { lanService = "" } // IP を入力したら、一覧の選択は外す
            }

            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "ペアリングコード (初回のみ)", systemImage: "key.fill", tint: Theme.amber)
                FieldRow(systemImage: "lock.rectangle.stack") {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $pairingCode)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focused)
                }
                Text("Windows で RDHost --pair を実行すると表示されます。登録は同じ Wi-Fi からだけ、Windows の画面での許可も必要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .card()
        }
    }

    private var relayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "中継サーバー", systemImage: "server.rack", tint: Theme.indigo)
            FieldRow(systemImage: "link") {
                TextField("https://xxxx.onrender.com", text: $relayURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("通り道").font(.subheadline.weight(.semibold))
                Picker("通り道", selection: $relayTransportRaw) {
                    Text("自動").tag(RelayTransportMode.auto.rawValue)
                    Text("WebSocket").tag(RelayTransportMode.webSocket.rawValue)
                    Text("HTTP").tag(RelayTransportMode.http.rawValue)
                }
                .pickerStyle(.segmented)
                Text("自動: WebSocket を試し、つながらなければ普通の HTTP 通信に切り替えます。会社や公衆 Wi-Fi のプロキシでつながらないときは「HTTP」を選んでください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label("中継サーバーには暗号化された通信しか流れません。部屋 ID は初回の接続で自動的に受け取っています。",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: 接続

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: 10) {
                if session.phase == .connecting {
                    ProgressView().tint(.white)
                    Text("接続しています…")
                } else {
                    Image(systemName: "bolt.horizontal.circle.fill")
                    Text("接続")
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle(busy: session.phase == .connecting))
        .disabled(session.phase != .idle)
        .padding(.top, 4)
    }

    private var securityBadges: some View {
        HStack(spacing: 16) {
            Label("端末間暗号化", systemImage: "lock.fill")
            Label("Face ID", systemImage: "faceid")
            Label("耐量子暗号", systemImage: "atom")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.top, 4)
    }

    private func connect() {
        focused = false
        var code: PairingCode?
        let trimmed = pairingCode.trimmingCharacters(in: .whitespaces)
        if mode == .lan && !trimmed.isEmpty {
            guard let c = PairingCode.parse(trimmed) else {
                session.alert = .init(title: "ペアリングコードの形式が正しくありません",
                                      message: "4 文字 × 6 組 (24 文字) を入力してください。")
                return
            }
            code = c
        }
        pairingCode = "" // 使い捨てなので残さない
        switch mode {
        case .lan:
            let host = lanHost.trimmingCharacters(in: .whitespaces)
            if host.isEmpty && !lanService.isEmpty {
                hostName = lanService
                session.connect(endpoint: .bonjour(name: lanService), pairingCode: code)
                return
            }
            guard !host.isEmpty else {
                session.alert = .init(title: "接続する PC を選んでください",
                                      message: "「この Wi-Fi で見つかった PC」から選ぶか、IP アドレスを入力してください。")
                return
            }
            if hostName.isEmpty || code != nil { hostName = host }
            session.connect(endpoint: .direct(host: host, port: UInt16(lanPort) ?? defaultPort), pairingCode: code)
        case .relay:
            guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespaces)),
                  url.scheme == "https" || url.scheme == "wss" else {
                session.alert = .init(title: "中継サーバーの URL を確認してください", message: "https:// で始まる URL を入力してください。")
                return
            }
            RelayTransportMode.default = RelayTransportMode(rawValue: relayTransportRaw) ?? .auto
            session.connect(endpoint: .relay(url), pairingCode: nil)
        }
    }
}

/// 同じ Wi-Fi の RDHost を Bonjour で探す
final class HostFinder: ObservableObject {
    @Published var hosts: [String] = []
    private let browser = HostBrowser()

    init() {
        browser.onChange = { [weak self] in self?.hosts = $0 }
    }

    func start() { browser.start() }
    func stop() { browser.stop() }
}

/// 「3 分前」などの表記 (端末の言語設定によらず日本語で)
func relativeJapanese(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "たった今" }
    if s < 3600 { return "\(s / 60) 分前" }
    if s < 86400 { return "\(s / 3600) 時間前" }
    if s < 86400 * 7 { return "\(s / 86400) 日前" }
    return d.formatted(date: .numeric, time: .omitted)
}
