import SwiftUI
import UIKit

/// Windows のキー (スキャンコード)
enum WinKey {
    static let ctrl = RemoteKey.scancode(0x1D), alt = RemoteKey.scancode(0x38)
    static let shift = RemoteKey.scancode(0x2A), win = RemoteKey.scancode(0xE05B)
    static let esc = RemoteKey.scancode(0x01), tab = RemoteKey.scancode(0x0F), enter = RemoteKey.scancode(0x1C)
    static let backspace = RemoteKey.scancode(0x0E), delete = RemoteKey.scancode(0xE053)
    static let home = RemoteKey.scancode(0xE047), end = RemoteKey.scancode(0xE04F)
    static let pageUp = RemoteKey.scancode(0xE049), pageDown = RemoteKey.scancode(0xE051)
    static let up = RemoteKey.scancode(0xE048), down = RemoteKey.scancode(0xE050)
    static let left = RemoteKey.scancode(0xE04B), right = RemoteKey.scancode(0xE04D)
    static let printScreen = RemoteKey.scancode(0xE037), zenkaku = RemoteKey.scancode(0x29)
    static func f(_ n: Int) -> RemoteKey { .scancode(n <= 10 ? UInt16(0x3A + n) : (n == 11 ? 0x57 : 0x58)) }
    static func letter(_ c: Character) -> RemoteKey {
        let map: [Character: UInt16] = ["A": 0x1E, "C": 0x2E, "D": 0x20, "E": 0x12, "F": 0x21, "I": 0x17, "N": 0x31,
                                        "R": 0x13, "S": 0x1F, "V": 0x2F, "W": 0x11, "X": 0x2D, "Y": 0x15, "Z": 0x2C]
        return .scancode(map[c] ?? 0x1E)
    }
}

/// 押したままにする修飾キー (パネルで選ぶと、次のキーやクリックに 1 回だけ付く)
enum Modifier: String, CaseIterable, Identifiable {
    case ctrl = "Ctrl", alt = "Alt", shift = "Shift", win = "Win"
    var id: String { rawValue }
    var key: RemoteKey {
        switch self {
        case .ctrl: return WinKey.ctrl
        case .alt: return WinKey.alt
        case .shift: return WinKey.shift
        case .win: return WinKey.win
        }
    }
    var symbol: String {
        switch self {
        case .ctrl: return "control"
        case .alt: return "option"
        case .shift: return "shift"
        case .win: return "squareshape.split.2x2"
        }
    }
}

/// ショートカット (メニュー)
struct Shortcut: Identifiable {
    let title: String
    let systemImage: String
    let keys: [RemoteKey]
    var id: String { title }
}

enum Shortcuts {
    static let edit: [Shortcut] = [
        Shortcut(title: "コピー", systemImage: "doc.on.doc", keys: [WinKey.ctrl, WinKey.letter("C")]),
        Shortcut(title: "切り取り", systemImage: "scissors", keys: [WinKey.ctrl, WinKey.letter("X")]),
        Shortcut(title: "貼り付け", systemImage: "doc.on.clipboard", keys: [WinKey.ctrl, WinKey.letter("V")]),
        Shortcut(title: "元に戻す", systemImage: "arrow.uturn.backward", keys: [WinKey.ctrl, WinKey.letter("Z")]),
        Shortcut(title: "やり直し", systemImage: "arrow.uturn.forward", keys: [WinKey.ctrl, WinKey.letter("Y")]),
        Shortcut(title: "すべて選択", systemImage: "checkmark.rectangle.stack", keys: [WinKey.ctrl, WinKey.letter("A")]),
        Shortcut(title: "保存", systemImage: "square.and.arrow.down", keys: [WinKey.ctrl, WinKey.letter("S")]),
        Shortcut(title: "検索", systemImage: "magnifyingglass", keys: [WinKey.ctrl, WinKey.letter("F")]),
    ]
    static let window: [Shortcut] = [
        Shortcut(title: "アプリの切り替え", systemImage: "rectangle.on.rectangle", keys: [WinKey.alt, WinKey.tab]),
        Shortcut(title: "タスクビュー", systemImage: "square.grid.2x2", keys: [WinKey.win, WinKey.tab]),
        Shortcut(title: "ウィンドウを閉じる", systemImage: "xmark.rectangle", keys: [WinKey.alt, WinKey.f(4)]),
        Shortcut(title: "デスクトップを表示", systemImage: "menubar.dock.rectangle", keys: [WinKey.win, WinKey.letter("D")]),
        Shortcut(title: "最大化", systemImage: "arrow.up.left.and.arrow.down.right", keys: [WinKey.win, WinKey.up]),
        Shortcut(title: "最小化", systemImage: "arrow.down.right.and.arrow.up.left", keys: [WinKey.win, WinKey.down]),
    ]
    static let system: [Shortcut] = [
        Shortcut(title: "スタート", systemImage: "square.grid.3x3.fill", keys: [WinKey.win]),
        Shortcut(title: "エクスプローラー", systemImage: "folder", keys: [WinKey.win, WinKey.letter("E")]),
        Shortcut(title: "設定", systemImage: "gearshape", keys: [WinKey.win, WinKey.letter("I")]),
        Shortcut(title: "ファイル名を指定して実行", systemImage: "terminal", keys: [WinKey.win, WinKey.letter("R")]),
        Shortcut(title: "タスクマネージャー", systemImage: "chart.bar.doc.horizontal", keys: [WinKey.ctrl, WinKey.shift, WinKey.esc]),
        Shortcut(title: "画面の切り取り", systemImage: "camera.viewfinder", keys: [WinKey.win, WinKey.shift, WinKey.letter("S")]),
        Shortcut(title: "日本語入力の切り替え", systemImage: "character.ja", keys: [WinKey.zenkaku]),
    ]
}

/// リモート画面 + 操作用ツールバー
struct RemoteScreenContainer: View {
    @ObservedObject var session: ViewerSession
    @State private var showText = false
    @State private var text = ""
    @State private var showHelp = false
    @State private var showSettings = false
    @State private var showKeys = false
    @State private var toolbarOpen = true
    @State private var confirmDisconnect = false
    @State private var shareItem: ShareImage?
    @AppStorage(SettingsKey.showStats) private var showStats = false
    @StateObject private var controller = RemoteViewController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteViewRepresentable(session: session, controller: controller)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                toolbar
                if let t = controller.toast {
                    ToastView(text: t.text, systemImage: t.systemImage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if showStats { StatsHUD(stats: session.stats).transition(.opacity) }
                    Spacer()
                }
                if showKeys {
                    KeysPanel(controller: controller)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showKeys)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toolbarOpen)
            .animation(.easeInOut(duration: 0.25), value: controller.toast?.id)
        }
        .statusBar(hidden: true)
        .sheet(isPresented: $showText) { textSheet }
        .sheet(isPresented: $showHelp) { GestureHelp { showHelp = false } }
        .sheet(isPresented: $showSettings) { SettingsView(session: session) }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.image]) }
        .confirmationDialog("切断しますか?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("切断", role: .destructive) { session.disconnect() }
        }
        #if RD_SCREENSHOTS
        .onReceive(ScreenshotDriver.shared.showTextSheet) { t in
            text = t
            showText = !t.isEmpty
        }
        .onReceive(ScreenshotDriver.shared.toggleKeyboard) { controller.toggleKeyboard() }
        .onReceive(ScreenshotDriver.shared.showKeys) { showKeys = $0 }
        .onReceive(ScreenshotDriver.shared.showStats) { showStats = $0 }
        .onReceive(ScreenshotDriver.shared.showSettings) { showSettings = $0 }
        .onReceive(ScreenshotDriver.shared.showHelp) { showHelp = $0 }
        #endif
    }

    // MARK: ツールバー

    @ViewBuilder private var toolbar: some View {
        if toolbarOpen {
            HStack(spacing: 4) {
                connectionBadge
                divider
                ToolButton("keyboard", "キーボード") { controller.toggleKeyboard() }
                ToolButton("character.cursor.ibeam", "文字入力") { showText = true }
                ToolButton("command", "特殊キー", active: showKeys) { showKeys.toggle() }
                shortcutsMenu
                ToolButton("doc.on.clipboard", "クリップボードを送信") { sendClipboard() }
                ToolButton("camera", "スクリーンショット") { screenshot() }
                if controller.zoomed {
                    ToolButton("arrow.down.right.and.arrow.up.left", "等倍に戻す") { controller.resetZoom() }
                }
                divider
                ToolButton("speedometer", "通信状況", active: showStats) { showStats.toggle() }
                ToolButton("hand.tap", "操作方法") { showHelp = true }
                ToolButton("gearshape", "設定") { showSettings = true }
                ToolButton("chevron.up", "ツールバーをしまう") { toolbarOpen = false }
                divider
                Button { confirmDisconnect = true } label: {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.red.gradient, in: Circle())
                }
                .accessibilityLabel("切断")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            Button { toolbarOpen = true } label: {
                HStack(spacing: 6) {
                    Image("Logo").resizable().frame(width: 18, height: 18)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(.top, 2)
            .accessibilityLabel("ツールバーを表示")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(qualityColor).frame(width: 8, height: 8)
            Image(systemName: "lock.fill").font(.caption2)
        }
        .padding(.horizontal, 8)
        .help("\(session.securitySummary)\n\(session.hostFingerprint)")
        .accessibilityLabel("暗号化された接続")
    }

    private var qualityColor: Color {
        // 画面が止まっていれば何も届かない (0 fps) のは正常
        session.stats.fps >= 8 || session.stats.fps == 0 ? .green : (session.stats.fps >= 3 ? .orange : .red)
    }

    private var shortcutsMenu: some View {
        Menu {
            section("編集", Shortcuts.edit)
            section("ウィンドウ", Shortcuts.window)
            section("Windows", Shortcuts.system)
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
        }
        .tint(.primary) // メニューの見出しを他のボタンと同じ色に
        .accessibilityLabel("ショートカット")
    }

    private func section(_ title: String, _ items: [Shortcut]) -> some View {
        Section(title) {
            ForEach(items) { s in
                Button { controller.tap(s.keys); controller.flash(s.title, systemImage: s.systemImage) } label: {
                    Label(s.title, systemImage: s.systemImage)
                }
            }
        }
    }

    // MARK: 操作

    private func sendClipboard() {
        guard let s = UIPasteboard.general.string, !s.isEmpty else {
            controller.flash("クリップボードに文字がありません", systemImage: "doc.on.clipboard")
            return
        }
        // 長すぎる文字列は分けて送る (1 メッセージ 1KB まで)
        var rest = Substring(s)
        while !rest.isEmpty {
            var chunk = ""
            while let c = rest.first, chunk.utf8.count + String(c).utf8.count <= ClientEvent.maxTextBytes {
                chunk.append(c)
                rest = rest.dropFirst()
            }
            if chunk.isEmpty { break }
            session.send(.text(chunk))
        }
        controller.flash("クリップボードを送信しました (\(s.count) 文字)", systemImage: "checkmark.circle.fill")
    }

    private func screenshot() {
        guard let img = session.lastImage else { return }
        shareItem = ShareImage(image: UIImage(cgImage: img))
    }

    private var textSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("送る文字", text: $text, axis: .vertical)
                        .lineLimit(3 ... 8)
                        .onSubmit(sendText)
                } footer: {
                    Text("日本語などはここで入力して確定すると、そのまま Windows に入力されます。")
                }
                Section {
                    Button { sendText() } label: { Label("送信", systemImage: "paperplane.fill") }
                    Button {
                        sendText()
                        controller.tap([WinKey.enter])
                    } label: { Label("送信して Enter", systemImage: "return") }
                }
            }
            .navigationTitle("文字入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("閉じる") { showText = false } }
        }
        .navigationViewStyle(.stack)
    }

    private func sendText() {
        if !text.isEmpty { session.send(.text(text)) }
        text = ""
        showText = false
    }
}

/// ツールバーのボタン
struct ToolButton: View {
    let systemImage: String
    let label: String
    var active = false
    let action: () -> Void

    init(_ systemImage: String, _ label: String, active: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? .white : .primary)
                .frame(width: 34, height: 34)
                .background {
                    if active { Circle().fill(Theme.brand) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// 特殊キーのパネル (修飾キー・矢印・ファンクションキー)
struct KeysPanel: View {
    @ObservedObject var controller: RemoteViewController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Modifier.allCases) { m in
                    let on = controller.modifiers.contains(m)
                    Button { controller.toggle(m) } label: {
                        Label(m.rawValue, systemImage: m.symbol)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(on ? .white : .primary)
                            .background {
                                if on {
                                    Capsule().fill(Theme.brand)
                                } else {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 8)
                Group {
                    key("Esc", WinKey.esc)
                    key("Tab", WinKey.tab)
                    keyIcon("delete.left", WinKey.backspace)
                    key("Del", WinKey.delete)
                    keyIcon("return", WinKey.enter)
                }
                arrows
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(1 ... 12, id: \.self) { n in key("F\(n)", WinKey.f(n)) }
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 24)
                    key("Home", WinKey.home)
                    key("End", WinKey.end)
                    key("PgUp", WinKey.pageUp)
                    key("PgDn", WinKey.pageDown)
                    key("PrtSc", WinKey.printScreen)
                    key("半/全", WinKey.zenkaku)
                }
            }
            if !controller.modifiers.isEmpty {
                Text("\(controller.modifiers.map(\.rawValue).sorted().joined(separator: " + ")) を次のキーまたはクリックに付けます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .frame(maxWidth: 900)
    }

    private var arrows: some View {
        HStack(spacing: 3) {
            keyIcon("arrow.left", WinKey.left)
            VStack(spacing: 3) {
                keyIcon("arrow.up", WinKey.up, small: true)
                keyIcon("arrow.down", WinKey.down, small: true)
            }
            keyIcon("arrow.right", WinKey.right)
        }
    }

    private func key(_ title: String, _ k: RemoteKey) -> some View {
        Button { controller.tap([k]) } label: {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .frame(minWidth: 38)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func keyIcon(_ systemImage: String, _ k: RemoteKey, small: Bool = false) -> some View {
        Button { controller.tap([k]) } label: {
            Image(systemName: systemImage)
                .font(.system(size: small ? 11 : 14, weight: .semibold))
                .frame(width: 36, height: small ? 15 : 34)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: small ? 6 : 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 通信状況 (左下)
struct StatsHUD: View {
    let stats: ViewerSession.Stats

    var body: some View {
        HStack(spacing: 10) {
            Label(stats.fps == 0 ? "静止" : "\(stats.fps) fps", systemImage: "film")
            Label(stats.kbps >= 1000 ? String(format: "%.1f Mbps", stats.kbps / 1000) : String(format: "%.0f kbps", stats.kbps),
                  systemImage: "arrow.down.circle")
            Label(String(format: "計 %.1f MB", Double(stats.totalBytes) / 1_048_576), systemImage: "sum")
        }
        .font(.system(.caption, design: .monospaced).weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
}

/// 短いお知らせ
struct ToastView: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// 共有シート (スクリーンショットの保存・送信)
struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 操作方法の一覧
struct GestureHelp: View {
    let close: () -> Void

    private struct Row: Identifiable {
        let systemImage: String
        let gesture: String
        let action: String
        var id: String { gesture }
        init(_ i: String, _ g: String, _ a: String) { systemImage = i; gesture = g; action = a }
    }

    private let finger: [Row] = [
        Row("hand.point.up.left", "1 本指でなぞる", "カーソル移動"),
        Row("hand.tap", "1 本指でタップ", "左クリック (2 回でダブルクリック)"),
        Row("hand.tap.fill", "2 本指でタップ", "右クリック"),
        Row("hand.raised", "3 本指でタップ", "中クリック"),
        Row("arrow.up.and.down.and.sparkles", "2 本指で動かす", "スクロール"),
        Row("hand.point.up.braille", "長押ししてから動かす", "ドラッグ (範囲選択・ウィンドウの移動)"),
        Row("arrow.up.left.and.down.right.magnifyingglass", "ピンチ", "表示の拡大・縮小 (拡大中はカーソルを追って動く)"),
    ]
    private let pointer: [Row] = [
        Row("cursorarrow", "動かす", "カーソルがポインタの位置に"),
        Row("cursorarrow.click", "クリック / 副ボタン", "左クリック / 右クリック"),
        Row("cursorarrow.motionlines", "押したまま動かす", "ドラッグ"),
        Row("computermouse", "ホイール / 2 本指", "スクロール"),
    ]
    private let toolbar: [Row] = [
        Row("command", "特殊キー", "Ctrl・Alt・Shift・Win を次の操作に付ける。矢印・F1〜F12 など"),
        Row("bolt.fill", "ショートカット", "コピー・貼り付け・アプリ切り替え・タスクマネージャーなど"),
        Row("doc.on.clipboard", "クリップボード", "iPad でコピーした文字を Windows に入力"),
        Row("camera", "スクリーンショット", "今の画面を保存・共有"),
    ]

    var body: some View {
        NavigationView {
            List {
                Section("指で (トラックパッドのように)") { ForEach(finger) { row($0) } }
                Section("マウス / トラックパッドをつないだとき") { ForEach(pointer) { row($0) } }
                Section("ツールバー") { ForEach(toolbar) { row($0) } }
            }
            .navigationTitle("操作方法")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("閉じる", action: close) }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ r: Row) -> some View {
        HStack(spacing: 14) {
            Image(systemName: r.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.gesture).font(.body.weight(.semibold))
                Text(r.action).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// SwiftUI から UIView を操作するための橋渡し
final class RemoteViewController: ObservableObject {
    struct Toast: Equatable {
        let id = UUID()
        let text: String
        let systemImage: String
    }

    weak var view: RemoteUIView? {
        didSet {
            view?.onZoomChange = { [weak self] z in
                DispatchQueue.main.async { self?.zoomed = z > 1 } // SwiftUI の描画中に変更しない
            }
            view?.consumeModifiers = { [weak self] in self?.takeModifiers() ?? [] }
        }
    }
    @Published var zoomed = false
    @Published var modifiers: Set<Modifier> = []
    @Published var toast: Toast?

    func toggleKeyboard() { view?.toggleKeyboard() }
    func tap(_ keys: [RemoteKey]) { view?.tap(takeModifiers() + keys) }
    func resetZoom() { view?.resetZoom() }

    func toggle(_ m: Modifier) {
        if modifiers.contains(m) { modifiers.remove(m) } else { modifiers.insert(m) }
    }

    /// 選んである修飾キーを取り出して、選択を解く (1 回だけ付ける)
    private func takeModifiers() -> [RemoteKey] {
        let keys = Modifier.allCases.filter { modifiers.contains($0) }.map(\.key)
        if !modifiers.isEmpty { modifiers.removeAll() }
        return keys
    }

    func flash(_ text: String, systemImage: String) {
        let t = Toast(text: text, systemImage: systemImage)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toast == t { self?.toast = nil }
        }
    }
}

struct RemoteViewRepresentable: UIViewRepresentable {
    let session: ViewerSession
    let controller: RemoteViewController

    func makeUIView(context: Context) -> RemoteUIView {
        let v = RemoteUIView(session: session)
        controller.view = v
        return v
    }

    func updateUIView(_ uiView: RemoteUIView, context: Context) {
        uiView.remoteSize = session.remoteSize
    }
}

/// 画面表示とタッチ・キーボード入力。
///
/// 指での操作はトラックパッド方式 (カーソルは指の位置ではなく、動かした分だけ動く):
///   1 本指でなぞる: カーソル移動      1 本指タップ: 左クリック (2 回でダブルクリック)
///   2 本指タップ: 右クリック          3 本指タップ: 中クリック
///   2 本指で動かす: スクロール        長押ししてから動かす: ドラッグ
///   ピンチ: 表示の拡大・縮小 (拡大中はカーソルを追って表示が動く)
/// マウス / トラックパッドをつないだ場合は、ポインタの位置がそのままカーソルになる
/// (左クリック・右クリック・ドラッグ・ホイール)。
final class RemoteUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    private let session: ViewerSession
    private let imageLayer = CALayer()
    private let cursorLayer = CAShapeLayer()
    private var cursor = CGPoint.zero // リモート画面のピクセル座標
    private var pressed: [UIKeyboardHIDUsage: RemoteKey] = [:]
    private var scrollAccum = CGPoint.zero
    private var lastLongPress = CGPoint.zero
    private var keyboardVisible = false

    // 表示の拡大 (1 = 全体が収まる大きさ)。viewCenter は表示の中心にあるリモート画面の座標
    static let maxZoom: CGFloat = 5
    private(set) var zoom: CGFloat = 1
    private var viewCenter = CGPoint.zero
    private var pinchStartZoom: CGFloat = 1
    private var pinchAnchor = CGPoint.zero
    private weak var pinch: UIPinchGestureRecognizer?
    /// 拡大率が変わったとき (ツールバーの「等倍」ボタン用)
    var onZoomChange: ((CGFloat) -> Void)?
    /// 特殊キーのパネルで選んだ修飾キー (次のクリックに 1 回だけ付ける)
    var consumeModifiers: (() -> [RemoteKey])?
    private let tapFeedback = UIImpactFeedbackGenerator(style: .soft)

    var remoteSize = CGSize.zero {
        didSet {
            guard remoteSize != oldValue else { return }
            cursor = CGPoint(x: remoteSize.width / 2, y: remoteSize.height / 2)
            viewCenter = cursor
            setZoom(1)
            setNeedsLayout()
        }
    }

    init(session: ViewerSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        imageLayer.contentsGravity = .resize // 大きさと位置は videoRect で決める
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)

        let arrow = UIBezierPath()
        arrow.move(to: .zero)
        arrow.addLine(to: CGPoint(x: 0, y: 17))
        arrow.addLine(to: CGPoint(x: 4.5, y: 13))
        arrow.addLine(to: CGPoint(x: 8, y: 20))
        arrow.addLine(to: CGPoint(x: 10.5, y: 19))
        arrow.addLine(to: CGPoint(x: 7, y: 12))
        arrow.addLine(to: CGPoint(x: 12, y: 12))
        arrow.close()
        cursorLayer.path = arrow.cgPath
        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.black.cgColor
        cursorLayer.lineWidth = 1
        layer.addSublayer(cursorLayer)

        session.onImage = { [weak self] img in
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.imageLayer.contents = img
                CATransaction.commit()
            }
        }
        setupGestures()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
    }

    private func applyLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let smooth = SettingsKey.bool(SettingsKey.smoothScaling, true)
        imageLayer.magnificationFilter = smooth ? .linear : .nearest
        imageLayer.frame = videoRect
        updateCursorLayer()
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() } // ハードウェアキーボードを受け取る
    }

    // MARK: 座標

    /// 画面に表示しているリモート画面全体の矩形 (拡大中は bounds からはみ出す)
    private var videoRect: CGRect {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return bounds }
        let fit = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
        let s = fit * zoom
        let w = remoteSize.width * s, h = remoteSize.height * s
        func origin(_ size: CGFloat, _ view: CGFloat, _ center: CGFloat, _ mid: CGFloat) -> CGFloat {
            // 収まるなら中央、はみ出すなら viewCenter を中心にして、端より外は見せない
            if size <= view { return (view - size) / 2 }
            return min(0, max(view - size, mid - center * s))
        }
        return CGRect(x: origin(w, bounds.width, viewCenter.x, bounds.midX),
                      y: origin(h, bounds.height, viewCenter.y, bounds.midY), width: w, height: h)
    }

    private var pixelsPerPoint: CGFloat {
        let r = videoRect
        return r.width > 0 ? remoteSize.width / r.width : 1
    }

    private func remoteToView(_ p: CGPoint) -> CGPoint {
        let r = videoRect
        return CGPoint(x: r.minX + p.x / pixelsPerPoint, y: r.minY + p.y / pixelsPerPoint)
    }

    private func viewToRemote(_ p: CGPoint) -> CGPoint {
        let r = videoRect
        return CGPoint(x: (p.x - r.minX) * pixelsPerPoint, y: (p.y - r.minY) * pixelsPerPoint)
    }

    private func updateCursorLayer() {
        guard remoteSize.width > 0 else { cursorLayer.isHidden = true; return }
        cursorLayer.isHidden = false
        cursorLayer.position = remoteToView(cursor)
    }

    /// 表示の中心を、実際に表示されている位置に合わせ直す (端で止まった分を残さない)
    private func normalizeViewCenter() {
        guard remoteSize.width > 0 else { return }
        viewCenter = viewToRemote(CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func setZoom(_ z: CGFloat) {
        let nz = min(Self.maxZoom, max(1, z))
        guard nz != zoom else { return }
        zoom = nz
        onZoomChange?(zoom)
    }

    func resetZoom() {
        setZoom(1)
        viewCenter = CGPoint(x: remoteSize.width / 2, y: remoteSize.height / 2)
        applyLayout()
    }

    /// 拡大中、カーソルが表示の端に近づいたら表示を動かす
    private func followCursor() {
        guard zoom > 1 else { return }
        let p = remoteToView(cursor)
        let margin = min(bounds.width, bounds.height) * 0.15
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.x < bounds.minX + margin { dx = p.x - (bounds.minX + margin) }
        if p.x > bounds.maxX - margin { dx = p.x - (bounds.maxX - margin) }
        if p.y < bounds.minY + margin { dy = p.y - (bounds.minY + margin) }
        if p.y > bounds.maxY - margin { dy = p.y - (bounds.maxY - margin) }
        guard dx != 0 || dy != 0 else { return }
        viewCenter.x += dx * pixelsPerPoint
        viewCenter.y += dy * pixelsPerPoint
        imageLayer.frame = videoRect
        normalizeViewCenter()
    }

    private func moveCursor(to p: CGPoint, follow: Bool = true) {
        guard remoteSize.width > 0 else { return }
        cursor.x = min(max(0, p.x), remoteSize.width - 1)
        cursor.y = min(max(0, p.y), remoteSize.height - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if follow { followCursor() }
        updateCursorLayer()
        CATransaction.commit()
        session.send(.mouseMove(x: Int32(cursor.x), y: Int32(cursor.y)))
    }

    private func moveCursor(by delta: CGPoint) {
        // 指の移動量を表示の拡大率に合わせて、少し加速する (拡大中は細かく動かせる)
        let k = pixelsPerPoint * 1.4 * SettingsKey.double(SettingsKey.pointerSpeed, 1)
        moveCursor(to: CGPoint(x: cursor.x + delta.x * k, y: cursor.y + delta.y * k))
    }

    // MARK: ジェスチャー

    /// 指 (と Apple Pencil) だけ。マウス / トラックパッドのポインタは別の認識器で扱う
    private static let fingerTouches = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
    private static let pointerTouches = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

    private func setupGestures() {
        // --- 指 ---
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = []
        pan.allowedTouchTypes = Self.fingerTouches
        addGestureRecognizer(pan)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all // マウスホイール / トラックパッドの 2 本指スクロールも
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.allowedTouchTypes = Self.fingerTouches
        pinch.delegate = self
        addGestureRecognizer(pinch)
        self.pinch = pinch

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.numberOfTouchesRequired = 1
        tap.allowedTouchTypes = Self.fingerTouches
        addGestureRecognizer(tap)

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        twoTap.allowedTouchTypes = Self.fingerTouches
        addGestureRecognizer(twoTap)

        let threeTap = UITapGestureRecognizer(target: self, action: #selector(onThreeFingerTap(_:)))
        threeTap.numberOfTouchesRequired = 3
        threeTap.allowedTouchTypes = Self.fingerTouches
        addGestureRecognizer(threeTap)

        // 2 本指・3 本指で触れたときに、先に着いた 1 本目でクリックしない
        tap.require(toFail: twoTap)
        tap.require(toFail: threeTap)
        twoTap.require(toFail: threeTap)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        long.minimumPressDuration = 0.35
        long.allowedTouchTypes = Self.fingerTouches
        addGestureRecognizer(long)

        // --- マウス / トラックパッド (ポインタ) ---
        let pointerClick = UITapGestureRecognizer(target: self, action: #selector(onPointerClick(_:)))
        pointerClick.allowedTouchTypes = Self.pointerTouches
        pointerClick.buttonMaskRequired = .primary
        addGestureRecognizer(pointerClick)

        // 以前は指のタップもここで拾ってしまい、1 本指タップが右クリックになっていた
        let pointerSecondary = UITapGestureRecognizer(target: self, action: #selector(onPointerSecondary(_:)))
        pointerSecondary.allowedTouchTypes = Self.pointerTouches
        pointerSecondary.buttonMaskRequired = .secondary
        addGestureRecognizer(pointerSecondary)

        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(onPointerDrag(_:)))
        pointerDrag.allowedTouchTypes = Self.pointerTouches
        pointerDrag.allowedScrollTypesMask = []
        addGestureRecognizer(pointerDrag)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover) // ポインタの位置に追従
    }

    /// ピンチと 2 本指スクロールは同時に認識させ、ピンチ中はスクロールを送らない
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    private var isPinching: Bool {
        guard let p = pinch else { return false }
        return p.state == .began || p.state == .changed
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        moveCursor(by: t)
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if isPinching {
            scrollAccum = .zero
            return
        }
        // ナチュラルスクロール: 指の向きに中身が動く (iPad と同じ)。切ると逆
        let k = 3 * SettingsKey.double(SettingsKey.scrollSpeed, 1) * (SettingsKey.bool(SettingsKey.naturalScroll, true) ? 1 : -1)
        scrollAccum.x += -t.x * k
        scrollAccum.y += t.y * k
        let dx = Int32(scrollAccum.x.rounded(.towardZero)), dy = Int32(scrollAccum.y.rounded(.towardZero))
        scrollAccum.x -= CGFloat(dx)
        scrollAccum.y -= CGFloat(dy)
        if dx != 0 || dy != 0 { session.send(.mouseWheel(dx: dx, dy: dy)) }
        if g.state == .ended || g.state == .cancelled { scrollAccum = .zero }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard remoteSize.width > 0 else { return }
        let loc = g.location(in: self)
        switch g.state {
        case .began:
            pinchStartZoom = zoom
            pinchAnchor = viewToRemote(loc) // 指の間にある点が、指の下にとどまるように拡大する
        case .changed:
            setZoom(pinchStartZoom * g.scale)
            let fit = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
            let s = fit * zoom
            viewCenter = CGPoint(x: pinchAnchor.x + (bounds.midX - loc.x) / s,
                                 y: pinchAnchor.y + (bounds.midY - loc.y) / s)
            applyLayout()
            normalizeViewCenter()
        default:
            if zoom < 1.05 { resetZoom() } // ほぼ等倍まで戻したら、ぴったり等倍に
        }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        click(.left)
    }

    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        click(.right)
    }

    @objc private func onThreeFingerTap(_ g: UITapGestureRecognizer) {
        click(.middle)
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            lastLongPress = p
            if SettingsKey.bool(SettingsKey.haptics, true) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            heldModifiers = consumeModifiers?() ?? []
            for k in heldModifiers { session.send(k.event(down: true)) }
            session.send(.mouseButton(.left, down: true))
        case .changed:
            moveCursor(by: CGPoint(x: p.x - lastLongPress.x, y: p.y - lastLongPress.y))
            lastLongPress = p
        default:
            session.send(.mouseButton(.left, down: false))
            for k in heldModifiers.reversed() { session.send(k.event(down: false)) }
            heldModifiers = []
        }
    }

    /// 長押しドラッグ中に押している修飾キー (Shift + ドラッグで範囲選択など)
    private var heldModifiers: [RemoteKey] = []

    @objc private func onPointerClick(_ g: UITapGestureRecognizer) {
        moveCursor(to: viewToRemote(g.location(in: self)), follow: false)
        click(.left)
    }

    @objc private func onPointerSecondary(_ g: UITapGestureRecognizer) {
        moveCursor(to: viewToRemote(g.location(in: self)), follow: false)
        click(.right)
    }

    @objc private func onPointerDrag(_ g: UIPanGestureRecognizer) {
        moveCursor(to: viewToRemote(g.location(in: self)), follow: false)
        switch g.state {
        case .began: session.send(.mouseButton(.left, down: true))
        case .ended, .cancelled, .failed: session.send(.mouseButton(.left, down: false))
        default: break
        }
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .changed || g.state == .began else { return }
        // ポインタは画面上の位置そのものなので、表示は動かさない
        moveCursor(to: viewToRemote(g.location(in: self)), follow: false)
    }

    private func click(_ b: MouseButton) {
        if SettingsKey.bool(SettingsKey.haptics, true) { tapFeedback.impactOccurred(intensity: 0.6) }
        let mods = consumeModifiers?() ?? [] // Ctrl + クリックなど
        for k in mods { session.send(k.event(down: true)) }
        session.send(.mouseButton(b, down: true))
        session.send(.mouseButton(b, down: false))
        for k in mods.reversed() { session.send(k.event(down: false)) }
    }

    // MARK: キーボード

    override var canBecomeFirstResponder: Bool { true }

    private let noKeyboard = UIView(frame: .zero)

    func toggleKeyboard() {
        keyboardVisible.toggle()
        // 画面キーボードを出し入れする (ハードウェアキーボードは常に受け付ける)
        resignFirstResponder()
        becomeFirstResponder()
        reloadInputViews()
    }

    override var inputView: UIView? {
        // nil なら画面キーボード、空のビューなら画面キーボードを出さない
        keyboardVisible ? nil : noKeyboard
    }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        if text == "\n" {
            tap([.scancode(0x1C)])
        } else {
            session.send(.text(text))
        }
    }

    func deleteBackward() {
        tap([.scancode(0x0E)])
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for p in presses {
            guard let key = p.key,
                  let rk = HIDKeyMap.remoteKey(key.keyCode, commandAsControl: session.commandAsControl) else {
                unhandled.insert(p)
                continue
            }
            pressed[key.keyCode] = rk
            session.send(rk.event(down: true))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // 自分で処理したキー (押したときに送ったもの) 以外だけを UIKit に渡す
        let unhandled = presses.filter { p in p.key.map { pressed[$0.keyCode] == nil } ?? true }
        releasePresses(presses, with: event)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releasePresses(presses, with: event)
        super.pressesCancelled(presses, with: event)
    }

    private func releasePresses(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for p in presses {
            guard let key = p.key, let rk = pressed.removeValue(forKey: key.keyCode) else { continue }
            session.send(rk.event(down: false))
        }
    }

    /// キーを順に押して逆順に離す
    func tap(_ keys: [RemoteKey]) {
        for k in keys { session.send(k.event(down: true)) }
        for k in keys.reversed() { session.send(k.event(down: false)) }
    }

    override func resignFirstResponder() -> Bool {
        // 押しっぱなしのキーを残さない
        for (_, k) in pressed { session.send(k.event(down: false)) }
        pressed.removeAll()
        return super.resignFirstResponder()
    }
}
