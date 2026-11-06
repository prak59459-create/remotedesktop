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
    @AppStorage("lanService") private var lanService = "" // Bonjour で見つけて選んだ PC の名前
    @StateObject private var finder = HostFinder()
    @State private var pairingCode = ""

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .lan }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("接続方法", selection: $modeRaw) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .lan {
                    Section(header: Text("この Wi-Fi で見つかった PC"),
                            footer: Text("RDHost を起動した PC が自動で表示されます。出てこないときは、PC のネットワークを「プライベート」にするか、下に IP アドレスを入力してください。")) {
                        if finder.hosts.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("探しています…").foregroundColor(.secondary)
                            }
                        }
                        ForEach(finder.hosts, id: \.self) { name in
                            Button {
                                lanService = name
                                lanHost = ""
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    Text(name).foregroundColor(.primary)
                                    Spacer()
                                    if lanService == name { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                                }
                            }
                        }
                    }
                    Section(header: Text("または IP アドレスで指定"),
                            footer: Text("RDHost の画面に表示される IP アドレス (例: 192.168.0.10)")) {
                        TextField("IP アドレス", text: $lanHost)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("ポート", text: $lanPort)
                            .keyboardType(.numberPad)
                    }
                    .onChange(of: lanHost) { v in
                        if !v.isEmpty { lanService = "" } // IP を入力したら、一覧の選択は外す
                    }
                    Section(header: Text("ペアリングコード (初回のみ)"),
                            footer: Text("Windows で RDHost --pair を実行すると表示されます。登録は同じ Wi-Fi からのみ可能です。")) {
                        TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $pairingCode)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section(header: Text("中継サーバー"),
                            footer: Text("Windows 側で RDHost --relay に指定したのと同じ URL。中継サーバーには暗号化された通信しか流れません。")) {
                        TextField("https://xxxx.onrender.com", text: $relayURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section(header: Text("ペアリング済みのホスト")) {
                    if let fp = ViewerSession.savedHostFingerprint {
                        Text(fp).font(.system(.footnote, design: .monospaced))
                    } else {
                        Text("なし").foregroundColor(.secondary)
                    }
                }

                Section {
                    Toggle("⌘ を Ctrl として送る", isOn: $session.commandAsControl)
                }

                Section(footer: Text("Face ID を登録し直して接続できなくなったときに使います。リセット後はペアリングし直してください。")) {
                    Button("端末の鍵をリセット", role: .destructive) { session.resetDeviceKey() }
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if session.phase == .connecting {
                                ProgressView()
                            } else {
                                Text("接続").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(session.phase != .idle)
                }
            }
            .navigationTitle("リモートデスクトップ")
        }
        .navigationViewStyle(.stack)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        #if RD_SCREENSHOTS
        .onReceive(ScreenshotDriver.shared.pairingCode) { pairingCode = $0 }
        .onReceive(ScreenshotDriver.shared.pressConnect) { connect() }
        #endif
    }

    private func connect() {
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
                session.connect(endpoint: .bonjour(name: lanService), pairingCode: code)
                return
            }
            guard !host.isEmpty else {
                session.alert = .init(title: "接続する PC を選んでください",
                                      message: "「この Wi-Fi で見つかった PC」から選ぶか、IP アドレスを入力してください。")
                return
            }
            session.connect(endpoint: .direct(host: host, port: UInt16(lanPort) ?? defaultPort), pairingCode: code)
        case .relay:
            guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespaces)),
                  url.scheme == "https" || url.scheme == "wss" else {
                session.alert = .init(title: "中継サーバーの URL を確認してください", message: "https:// で始まる URL を入力してください。")
                return
            }
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
