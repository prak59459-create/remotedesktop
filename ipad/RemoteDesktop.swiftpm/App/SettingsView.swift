import SwiftUI

/// 設定のキー (UIKit 側からも UserDefaults で読む)
enum SettingsKey {
    static let pointerSpeed = "pointerSpeed"
    static let scrollSpeed = "scrollSpeed"
    static let naturalScroll = "naturalScroll"
    static let haptics = "haptics"
    static let showStats = "showStats"
    static let smoothScaling = "smoothScaling"

    static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}

struct SettingsView: View {
    @ObservedObject var session: ViewerSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.pointerSpeed) private var pointerSpeed = 1.0
    @AppStorage(SettingsKey.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(SettingsKey.naturalScroll) private var naturalScroll = true
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(SettingsKey.showStats) private var showStats = false
    @AppStorage(SettingsKey.smoothScaling) private var smoothScaling = true
    @State private var confirmReset = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    sliderRow("ポインタの速さ", systemImage: "cursorarrow.motionlines", value: $pointerSpeed)
                    sliderRow("スクロールの速さ", systemImage: "scroll", value: $scrollSpeed)
                    Toggle(isOn: $naturalScroll) {
                        Label("ナチュラルスクロール", systemImage: "hand.draw")
                    }
                    Toggle(isOn: $haptics) {
                        Label("触覚フィードバック", systemImage: "waveform")
                    }
                } header: {
                    Text("操作")
                } footer: {
                    Text("ナチュラルスクロール: 指を動かした向きに画面の中身が動きます (iPad と同じ)。")
                }

                Section("キーボード") {
                    Toggle(isOn: $session.commandAsControl) {
                        Label("⌘ を Ctrl として送る", systemImage: "command")
                    }
                }

                Section {
                    Toggle(isOn: $showStats) {
                        Label("通信状況を表示", systemImage: "speedometer")
                    }
                    Toggle(isOn: $smoothScaling) {
                        Label("画面をなめらかに拡大縮小", systemImage: "wand.and.rays")
                    }
                } header: {
                    Text("表示")
                } footer: {
                    Text("通信状況: 接続中の画面の左下に、フレームレートと受信量を表示します。")
                }

                Section {
                    if let fp = ViewerSession.savedHostFingerprint {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("ペアリング済みのホスト", systemImage: "desktopcomputer")
                            Text(fp).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("ペアリング済みのホストはありません", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { confirmReset = true } label: {
                        Label("端末の鍵をリセット", systemImage: "key.slash")
                    }
                } header: {
                    Text("セキュリティ")
                } footer: {
                    Text("Face ID を登録し直して接続できなくなったときに使います。リセット後はペアリングし直してください。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完了") { dismiss() }.bold() }
            .confirmationDialog("端末の鍵をリセットしますか?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("リセット", role: .destructive) {
                    session.resetDeviceKey()
                    dismiss()
                }
            } message: {
                Text("この iPad の鍵と、ペアリングした PC の情報が消えます。")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func sliderRow(_ title: String, systemImage: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(String(format: "%.1f×", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.4 ... 2.5, step: 0.1)
        }
    }
}

/// このアプリについて (仕組みと安全性)
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let features: [(String, String, String)] = [
        ("lock.shield.fill", "端末間で暗号化", "Noise プロトコルで暗号化と相互認証。中継サーバーにも中身は見えません。"),
        ("atom", "耐量子暗号", "対応する iPadOS では ML-KEM-768 も併用します。"),
        ("faceid", "Face ID で鍵を保護", "端末の鍵は Secure Enclave に。接続のたびに本人確認します。"),
        ("person.badge.key.fill", "ペアリングした端末だけ", "パスワードなし。登録は同じ Wi-Fi から、PC の画面での許可が必要です。"),
        ("arrow.down.circle.dotted", "通信量を節約", "画面が変わらなければ送らず、動いている間は粗く、止まったらきれいに。"),
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Image("Logo").resizable().frame(width: 110, height: 110)
                        .shadow(color: Theme.blue.opacity(0.4), radius: 20, y: 10)
                        .padding(.top, 20)
                    VStack(spacing: 4) {
                        Text("Remote Desktop").font(.system(.title, design: .rounded).bold())
                        Text("バージョン \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 12) {
                        ForEach(features.indices, id: \.self) { i in
                            let f = features[i]
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: f.0)
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(f.1).font(.headline)
                                    Text(f.2).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .card(padding: 14)
                        }
                    }
                    .frame(maxWidth: 600)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .background(AuroraBackground())
            .navigationTitle("このアプリについて")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("閉じる") { dismiss() } }
        }
        .navigationViewStyle(.stack)
    }
}
