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
                    Section(header: Text("Windows PC"), footer: Text("RDHost を起動した PC の IP アドレス (例: 192.168.0.10)")) {
                        TextField("IP アドレス", text: $lanHost)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("ポート", text: $lanPort)
                            .keyboardType(.numberPad)
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
            guard !host.isEmpty else {
                session.alert = .init(title: "IP アドレスを入力してください", message: "")
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
