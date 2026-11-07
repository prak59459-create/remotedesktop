#if os(Windows)
import Foundation
import RDCore
import RDHostKit
import WinSDK

// ホストの GUI 版。見出し (グラデーション) + 左のメニュー + 4 つのページ (ホーム・端末・設定・ログ)。
// 文字や枠は自前で描き (ダブルバッファ)、入力欄・チェックボックスだけ Windows の部品を使う。

private var app: HostWindow?

private func hostWndProc(_ hwnd: HWND?, _ msg: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT {
    if let a = app, let h = hwnd, let r = a.handle(h, msg, w, l) { return r }
    return DefWindowProcW(hwnd, msg, w, l)
}

/// 色 (アイコンと同じ配色)
private enum Palette {
    static let indigo = (88, 60, 255), blue = (56, 112, 255), cyan = (20, 210, 245)
    static let content = rgb(246, 247, 252), sidebar = rgb(238, 240, 250), card = rgb(255, 255, 255)
    static let border = rgb(226, 229, 240), text = rgb(28, 30, 48), sub = rgb(110, 115, 140)
    static let green = rgb(34, 170, 90), red = rgb(220, 60, 70), gray = rgb(150, 155, 170)
    static let navSelectedText = rgb(255, 255, 255), selection = rgb(236, 234, 255), brandText = rgb(70, 60, 220)
}

private enum ID {
    static let startStop = 100, pair = 101, copyCode = 102, copyEndpoint = 103
    static let devices = 200, revoke = 201, resetDevices = 202
    static let relayURL = 300, transport = 301, direct = 302, port = 303, bonjour = 304, confirm = 305
    static let onDisconnect = 306, idle = 307, fps = 308, scale = 309, kbps = 310, pq = 311
    static let autoStart = 312, tray = 313, login = 314, save = 320
    static let log = 400, verifyLog = 401, openFolder = 402
    // タスクトレイのメニュー
    static let trayOpen = 1001, trayPair = 1002, trayStartStop = 1003, trayQuit = 1004
}

private enum ButtonKind { case primary, secondary, danger }

final class HostWindow {
    let service: HostService
    var settings: HostSettings
    private(set) var hwnd: HWND?
    private let scale: Double
    private var page = 0
    private var controls: [Int: HWND] = [:]
    private var pageOf: [Int: Int] = [:]
    private var buttonKinds: [Int: (ButtonKind, COLORREF)] = [:]
    private var devices: [HostService.Device] = []
    private var knownSessions: Set<String> = []
    private var trayAdded = false
    private var toldAboutTray = false
    private var quitting = false
    private var flashText: String?
    private var flashUntil = Date.distantPast

    private let logLock = NSLock()
    private var pendingLog: [String] = []

    // フォント
    private let fTitle, fSubtitle, fH2, fBody, fBodyBold, fSmall, fMono, fCode, fIcon, fIconSmall, fStatus: HFONT?
    private let bigIcon: HICON?
    private let smallIcon: HICON?
    private var cardBrush: HBRUSH?
    private var contentBrush: HBRUSH?

    // 大きさ (論理ピクセル。scale を掛けて使う)
    private let clientW = 980, clientH = 680, headerH = 92, sidebarW = 210

    init(service: HostService, settings: HostSettings) {
        self.service = service
        self.settings = settings
        let screen = GetDC(nil)
        let sc = Double(GetDeviceCaps(screen, 88 /* LOGPIXELSX */)) / 96
        _ = ReleaseDC(nil, screen)
        scale = sc
        func px(_ v: Double) -> Int32 { Int32((v * sc).rounded()) }
        fTitle = makeFont("Segoe UI", px(24), bold: true)
        fSubtitle = makeFont("Segoe UI", px(13))
        fH2 = makeFont("Segoe UI", px(16), bold: true)
        fBody = makeFont("Segoe UI", px(13.5))
        fBodyBold = makeFont("Segoe UI", px(13.5), bold: true)
        fSmall = makeFont("Segoe UI", px(12))
        fMono = makeFont("Consolas", px(13))
        fCode = makeFont("Consolas", px(30), bold: true)
        fIcon = makeFont("Segoe MDL2 Assets", px(17))
        fIconSmall = makeFont("Segoe MDL2 Assets", px(12))
        fStatus = makeFont("Segoe UI", px(21), bold: true)
        let iconPath = exeDirectory() + "\\AppIcon.ico"
        bigIcon = loadIcon(iconPath, size: px(56))
        smallIcon = loadIcon(iconPath, size: Int32(GetSystemMetrics(49 /* SM_CXSMICON */)))
        cardBrush = CreateSolidBrush(Palette.card)
        contentBrush = CreateSolidBrush(Palette.content)
    }

    private func S(_ v: Int) -> Int32 { Int32((Double(v) * scale).rounded()) }
    private func R(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> RECT { makeRect(S(x), S(y), S(w), S(h)) }

    // MARK: 作成

    func create(show: Bool) {
        app = self
        let hInstance = GetModuleHandleW(nil)
        let className = "RemoteDesktopHostWindow"
        withWide(className) { cls in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.style = 0x0002 | 0x0001 // CS_HREDRAW | CS_VREDRAW
            wc.lpfnWndProc = { h, m, w, l in hostWndProc(h, m, w, l) }
            wc.hInstance = hInstance
            wc.hIcon = bigIcon
            wc.hIconSm = smallIcon
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512 /* IDC_ARROW */))
            wc.lpszClassName = cls
            _ = RegisterClassExW(&wc)

            let style = Style.overlapped | Style.caption | Style.sysMenu | Style.minimizeBox | Style.clipChildren
            var rc = RECT(left: 0, top: 0, right: S(clientW), bottom: S(clientH))
            _ = AdjustWindowRectEx(&rc, style, false, 0)
            let w = rc.right - rc.left, h = rc.bottom - rc.top
            let x = (GetSystemMetrics(0) - w) / 2, y = max(0, (GetSystemMetrics(1) - h) / 2)
            hwnd = withWide("Remote Desktop ホスト") { title in
                CreateWindowExW(0, cls, title, style, x, y, w, h, nil, nil, hInstance, nil)
            }
        }
        guard let hwnd else { return }
        if let i = bigIcon { _ = SendMessageW(hwnd, WM.setIcon, 1, lparam(UnsafeMutableRawPointer(i))) }
        if let i = smallIcon { _ = SendMessageW(hwnd, WM.setIcon, 0, lparam(UnsafeMutableRawPointer(i))) }
        createControls()
        loadSettingsIntoControls()
        setPage(0)
        addTrayIcon()
        _ = SetTimer(hwnd, 1, 1000, nil)

        service.onChange = { [weak self] in
            guard let h = self?.hwnd else { return }
            _ = PostMessageW(h, WM.app + 1, 0, 0)
        }
        service.onAudit = { [weak self] line in self?.appendLog("[監査] " + line) }
        let previous = HostLog.sink // 通信量の記録 (HostService) にも渡す
        HostLog.sink = { [weak self] line in
            previous(line)
            self?.appendLog(line)
        }
        refresh()
        if show {
            _ = ShowWindow(hwnd, 5 /* SW_SHOW */)
            _ = UpdateWindow(hwnd)
        }
    }

    private func appendLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logLock.lock()
        pendingLog.append("\(f.string(from: Date()))  \(line)")
        logLock.unlock()
        if let h = hwnd { _ = PostMessageW(h, WM.app + 2, 0, 0) }
    }

    @discardableResult
    private func add(_ cls: String, _ text: String, _ style: DWORD, _ r: RECT, id: Int, page: Int,
                     ex: DWORD = 0, font: HFONT? = nil) -> HWND? {
        let h = withWide(cls) { c in
            withWide(text) { t in
                CreateWindowExW(ex, c, t, Style.child | Style.tabStop | style, r.left, r.top, r.right - r.left,
                                r.bottom - r.top, hwnd, HMENU(bitPattern: id), GetModuleHandleW(nil), nil)
            }
        }
        if let h {
            controls[id] = h
            pageOf[id] = page
            _ = SendMessageW(h, WM.setFont, wparam(UnsafeMutableRawPointer(font ?? fBody)), 1)
        }
        return h
    }

    private func button(_ text: String, _ r: RECT, id: Int, page: Int, kind: ButtonKind, on bg: COLORREF) {
        add("BUTTON", text, Style.bsOwnerDraw, r, id: id, page: page, font: fBodyBold)
        buttonKinds[id] = (kind, bg)
    }

    private func checkbox(_ text: String, _ r: RECT, id: Int) {
        add("BUTTON", text, Style.bsAutoCheckbox, r, id: id, page: 2)
    }

    private func edit(_ r: RECT, id: Int, page: Int, number: Bool = false, cue: String? = nil) {
        let h = add("EDIT", "", Style.esAutoHScroll | (number ? Style.esNumber : 0), r, id: id, page: page,
                    ex: Style.exClientEdge)
        if let h, let cue {
            _ = withWide(cue) { SendMessageW(h, Msg.emSetCueBanner, 1, lparam(UnsafeMutableRawPointer(mutating: $0))) }
        }
    }

    private func combo(_ r: RECT, id: Int, items: [String]) {
        // ドロップダウンの高さは、開いたときの一覧を含めた大きさ
        let h = add("COMBOBOX", "", Style.cbsDropDownList | Style.vScroll,
                    RECT(left: r.left, top: r.top, right: r.right, bottom: r.top + S(220)), id: id, page: 2)
        for item in items {
            _ = withWide(item) { SendMessageW(h, Msg.cbAddString, 0, lparam(UnsafeMutableRawPointer(mutating: $0))) }
        }
    }

    private func createControls() {
        let cx = sidebarW + 24, cw = clientW - sidebarW - 48
        let right = cx + cw - 24 - 190
        // ホーム
        button("待ち受けを開始", R(right, 128, 190, 42), id: ID.startStop, page: 0, kind: .primary, on: Palette.card)
        button("ペアリングコードを表示", R(right, 326, 190, 42), id: ID.pair, page: 0, kind: .primary, on: Palette.card)
        button("コードをコピー", R(right, 378, 190, 36), id: ID.copyCode, page: 0, kind: .secondary, on: Palette.card)
        button("接続先をコピー", R(right, 180, 190, 36), id: ID.copyEndpoint, page: 0, kind: .secondary, on: Palette.card)
        // 端末
        add("LISTBOX", "", Style.lbsNotify | Style.lbsOwnerDrawFixed | Style.lbsNoIntegralHeight | Style.vScroll,
            R(cx + 20, 176, cw - 40, 400), id: ID.devices, page: 1)
        button("選んだ端末を取り消す", R(cx, 612, 210, 42), id: ID.revoke, page: 1, kind: .danger, on: Palette.content)
        button("すべて消去", R(cx + 222, 612, 150, 42), id: ID.resetDevices, page: 1, kind: .secondary, on: Palette.content)
        // 設定
        let lx = cx + 24, ctl = cx + 200
        func row(_ i: Int) -> Int { 168 + i * 34 }
        edit(R(ctl, row(0) - 2, 470, 28), id: ID.relayURL, page: 2, cue: "https://xxxx.onrender.com")
        combo(R(ctl, row(1) - 2, 220, 28), id: ID.transport, items: ["自動 (WebSocket → HTTP)", "WebSocket", "HTTP"])
        checkbox("同じ Wi-Fi からの直接接続を受け付ける", R(ctl, row(2), 330, 26), id: ID.direct)
        edit(R(ctl + 410, row(2) - 2, 80, 28), id: ID.port, page: 2, number: true)
        checkbox("iPad に PC の名前を知らせる (Bonjour)", R(ctl, row(3), 400, 26), id: ID.bonjour)
        checkbox("登録済みの端末でも、接続のたびに確認する", R(ctl, row(4), 400, 26), id: ID.confirm)
        combo(R(ctl, row(5) - 2, 220, 28), id: ID.onDisconnect, items: ["モニターを消す", "Windows をロックする", "何もしない"])
        edit(R(ctl, row(6) - 2, 80, 28), id: ID.idle, page: 2, number: true)
        edit(R(ctl, row(7) - 2, 80, 28), id: ID.fps, page: 2, number: true)
        combo(R(ctl + 150, row(7) - 2, 170, 28), id: ID.scale, items: ["等倍で送る", "縦横 1/2", "縦横 1/3", "縦横 1/4"])
        edit(R(ctl, row(8) - 2, 100, 28), id: ID.kbps, page: 2, number: true)
        checkbox("耐量子暗号に対応していない端末を拒否する", R(ctl, row(9), 400, 26), id: ID.pq)
        checkbox("起動したら、すぐに待ち受けを始める", R(ctl, row(10), 400, 26), id: ID.autoStart)
        checkbox("閉じるボタンでタスクトレイにしまう (終了しない)", R(ctl, row(11), 420, 26), id: ID.tray)
        checkbox("Windows にサインインしたら自動で起動する", R(ctl, row(12), 420, 26), id: ID.login)
        button("保存", R(cx + cw - 24 - 130, 124, 130, 38), id: ID.save, page: 2, kind: .primary, on: Palette.card)
        _ = lx
        // ログ
        add("EDIT", "", Style.esMultiline | Style.esReadOnly | Style.esAutoVScroll | Style.vScroll,
            R(cx + 20, 168, cw - 40, 416), id: ID.log, page: 3, ex: Style.exClientEdge, font: fMono)
        button("監査ログを検証", R(cx, 612, 170, 42), id: ID.verifyLog, page: 3, kind: .secondary, on: Palette.content)
        button("データのフォルダを開く", R(cx + 182, 612, 210, 42), id: ID.openFolder, page: 3, kind: .secondary,
               on: Palette.content)
    }

    private func ctl(_ id: Int) -> HWND? { controls[id] }

    private func setText(_ id: Int, _ s: String) {
        guard let h = ctl(id) else { return }
        _ = withWide(s) { SetWindowTextW(h, $0) }
    }

    private func getText(_ id: Int) -> String {
        guard let h = ctl(id) else { return "" }
        let n = GetWindowTextLengthW(h)
        var buf = [WCHAR](repeating: 0, count: Int(n) + 1)
        _ = GetWindowTextW(h, &buf, n + 1)
        return String(decoding: buf.prefix(Int(n)), as: UTF16.self)
    }

    private func setCheck(_ id: Int, _ on: Bool) { _ = SendMessageW(ctl(id), Msg.bmSetCheck, on ? 1 : 0, 0) }
    private func isChecked(_ id: Int) -> Bool { SendMessageW(ctl(id), Msg.bmGetCheck, 0, 0) == 1 }
    private func setSel(_ id: Int, _ i: Int) { _ = SendMessageW(ctl(id), Msg.cbSetCurSel, WPARAM(i), 0) }
    private func sel(_ id: Int) -> Int { Int(SendMessageW(ctl(id), Msg.cbGetCurSel, 0, 0)) }

    private func loadSettingsIntoControls() {
        let s = settings
        setText(ID.relayURL, s.relayURL)
        setSel(ID.transport, [RelayTransportMode.auto, .webSocket, .http].firstIndex { $0.rawValue == s.relayTransport } ?? 0)
        setCheck(ID.direct, s.direct)
        setText(ID.port, String(s.port))
        setCheck(ID.bonjour, s.bonjour)
        setCheck(ID.confirm, s.confirm)
        setSel(ID.onDisconnect, ["blank", "lock", "none"].firstIndex(of: s.onDisconnect) ?? 0)
        setText(ID.idle, String(Int(s.idleMinutes)))
        setText(ID.fps, String(Int(s.fps)))
        setSel(ID.scale, max(0, min(3, s.scale - 1)))
        setText(ID.kbps, String(Int(s.maxKbps)))
        setCheck(ID.pq, s.requirePostQuantum)
        setCheck(ID.autoStart, s.autoStart)
        setCheck(ID.tray, s.closeToTray)
        setCheck(ID.login, StartupRegistration.isEnabled)
        RelayTransportMode.default = RelayTransportMode(rawValue: s.relayTransport) ?? .auto
    }

    private func settingsFromControls() -> HostSettings {
        var s = settings
        s.relayURL = getText(ID.relayURL).trimmingCharacters(in: .whitespaces)
        s.relayTransport = [RelayTransportMode.auto, .webSocket, .http][max(0, min(2, sel(ID.transport)))].rawValue
        s.direct = isChecked(ID.direct)
        s.port = Int(getText(ID.port)) ?? Int(defaultPort)
        s.bonjour = isChecked(ID.bonjour)
        s.confirm = isChecked(ID.confirm)
        s.onDisconnect = ["blank", "lock", "none"][max(0, min(2, sel(ID.onDisconnect)))]
        s.idleMinutes = Double(getText(ID.idle)) ?? 15
        s.fps = Double(getText(ID.fps)) ?? 30
        s.scale = max(0, sel(ID.scale)) + 1
        s.maxKbps = Double(getText(ID.kbps)) ?? 0
        s.requirePostQuantum = isChecked(ID.pq)
        s.autoStart = isChecked(ID.autoStart)
        s.closeToTray = isChecked(ID.tray)
        return s
    }

    // MARK: ページ

    func setPage(_ p: Int) {
        page = p
        for (id, h) in controls {
            let visible = pageOf[id] == p && (id != ID.copyCode || service.pairing != nil)
                && (id != ID.copyEndpoint || service.directEndpoint != nil)
            _ = ShowWindow(h, visible ? 5 : 0)
        }
        if p == 1 { reloadDevices() }
        if let h = hwnd { _ = InvalidateRect(h, nil, false) }
    }

    private var navItems: [(glyph: String, title: String)] {
        [("\u{E80F}", "ホーム"), ("\u{E8EA}", "端末"), ("\u{E713}", "設定"), ("\u{E8A5}", "ログ")]
    }

    private func navRect(_ i: Int) -> RECT { R(14, headerH + 24 + i * 52, sidebarW - 28, 44) }

    // MARK: 操作

    func startService() {
        RelayTransportMode.default = RelayTransportMode(rawValue: settings.relayTransport) ?? .auto
        do {
            try service.start()
        } catch {
            alert("待ち受けを始められませんでした", "\(error)", warning: true)
        }
        refresh()
    }

    private func toggleService() {
        if service.isRunning { service.stop() } else { startService() }
        refresh()
    }

    private func pair() {
        if !service.isRunning { startService() }
        guard service.isRunning else { return }
        service.startPairing()
        setPage(0)
        if let h = hwnd {
            _ = ShowWindow(h, 9 /* SW_RESTORE */)
            _ = SetForegroundWindow(h)
        }
        refresh()
    }

    private func save() {
        let s = settingsFromControls()
        if let problem = s.problem {
            alert("設定を確認してください", problem, warning: true)
            return
        }
        do {
            try s.save()
        } catch {
            alert("設定を保存できませんでした", "\(error)", warning: true)
            return
        }
        settings = s
        StartupRegistration.set(isChecked(ID.login))
        RelayTransportMode.default = RelayTransportMode(rawValue: s.relayTransport) ?? .auto
        do {
            try service.update(options: s.options)
            flash(service.isRunning ? "保存しました。新しい設定で待ち受けを始め直しました" : "保存しました")
        } catch {
            alert("待ち受けを始め直せませんでした", "\(error)", warning: true)
        }
        refresh()
    }

    private func revokeSelected() {
        let i = Int(SendMessageW(ctl(ID.devices), Msg.lbGetCurSel, 0, 0))
        guard i >= 0, i < devices.count else {
            alert("端末を選んでください", "取り消す端末を一覧から選んでください。", warning: false)
            return
        }
        let d = devices[i]
        guard confirm("「\(d.name)」の登録を取り消しますか?",
                      "この端末は接続できなくなります (接続中なら切断されます)。もう一度使うには、ペアリングし直しが必要です。")
        else { return }
        do {
            try service.revoke(d.fingerprint)
            flash("「\(d.name)」の登録を取り消しました")
        } catch {
            alert("取り消せませんでした", "\(error)", warning: true)
        }
        reloadDevices()
    }

    private func resetDevices() {
        guard confirm("登録済みの端末をすべて消しますか?", "すべての端末が接続できなくなります。もう一度使うには、ペアリングし直しが必要です。")
        else { return }
        do {
            try service.resetDevices()
            flash("登録済みの端末をすべて消しました")
        } catch {
            alert("消せませんでした", "\(error)", warning: true)
        }
        reloadDevices()
    }

    private func reloadDevices() {
        devices = service.devices
        guard let lb = ctl(ID.devices) else { return }
        _ = SendMessageW(lb, Msg.lbResetContent, 0, 0)
        for d in devices {
            _ = withWide(d.name) { SendMessageW(lb, Msg.lbAddString, 0, lparam(UnsafeMutableRawPointer(mutating: $0))) }
        }
        if let h = hwnd { _ = InvalidateRect(h, nil, false) }
    }

    private func openDataFolder() {
        guard let path = try? DataDirectory.url().path else { return }
        _ = withWide("open") { verb in withWide(path) { p in ShellExecuteW(hwnd, verb, p, nil, nil, 5) } }
    }

    private func flash(_ s: String) {
        flashText = s
        flashUntil = Date().addingTimeInterval(4)
        if let h = hwnd { _ = InvalidateRect(h, nil, false) }
    }

    private func alert(_ title: String, _ text: String, warning: Bool) {
        _ = withWide(text) { t in
            withWide(title) { c in MessageBoxW(hwnd, t, c, warning ? 0x30 : 0x40) }
        }
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        withWide(text) { t in
            withWide(title) { c in MessageBoxW(hwnd, t, c, 0x4 | 0x30 | 0x100) } // YESNO | WARNING | DEFBUTTON2
        } == 6
    }

    /// 状態の変化をウィンドウに反映する
    func refresh() {
        guard let hwnd else { return }
        setText(ID.startStop, service.isRunning ? "待ち受けを停止" : "待ち受けを開始")
        buttonKinds[ID.startStop] = (service.isRunning ? .secondary : .primary, Palette.card)
        if page == 0 {
            if let h = ctl(ID.copyCode) { _ = ShowWindow(h, service.pairing != nil ? 5 : 0) }
            if let h = ctl(ID.copyEndpoint) { _ = ShowWindow(h, service.directEndpoint != nil ? 5 : 0) }
        }
        if let h = ctl(ID.startStop) { _ = InvalidateRect(h, nil, false) }
        // 新しく接続した端末を知らせる
        let now = Set(service.sessions)
        for name in now.subtracting(knownSessions) { balloon("接続されました", "「\(name)」がこの PC に接続しました") }
        knownSessions = now
        updateTrayTip()
        _ = InvalidateRect(hwnd, nil, false)
    }

    // MARK: タスクトレイ

    private func setTuple<T>(_ tuple: inout T, _ s: String) {
        withUnsafeMutableBytes(of: &tuple) { buf in
            let cap = buf.count / 2
            let units = Array(s.utf16.prefix(cap - 1)) + [0]
            for (i, u) in units.enumerated() { buf.storeBytes(of: u, toByteOffset: i * 2, as: UInt16.self) }
        }
    }

    private func trayData() -> NOTIFYICONDATAW {
        var nid = NOTIFYICONDATAW()
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = hwnd
        nid.uID = 1
        return nid
    }

    private func addTrayIcon() {
        var nid = trayData()
        nid.uFlags = 0x1 | 0x2 | 0x4 // NIF_MESSAGE | NIF_ICON | NIF_TIP
        nid.uCallbackMessage = WM.app + 3
        nid.hIcon = smallIcon
        setTuple(&nid.szTip, "Remote Desktop ホスト")
        trayAdded = Shell_NotifyIconW(0 /* NIM_ADD */, &nid)
    }

    private func updateTrayTip() {
        guard trayAdded else { return }
        var nid = trayData()
        nid.uFlags = 0x4
        let state = !service.isRunning ? "停止中" : (service.sessions.isEmpty ? "待ち受け中" : "接続中: \(service.sessions.joined(separator: "、"))")
        setTuple(&nid.szTip, "Remote Desktop ホスト — \(state)")
        _ = Shell_NotifyIconW(1 /* NIM_MODIFY */, &nid)
    }

    private func balloon(_ title: String, _ text: String) {
        guard trayAdded else { return }
        var nid = trayData()
        nid.uFlags = 0x10 // NIF_INFO
        setTuple(&nid.szInfoTitle, title)
        setTuple(&nid.szInfo, text)
        nid.dwInfoFlags = 0x1 // NIIF_INFO
        _ = Shell_NotifyIconW(1, &nid)
    }

    private func removeTrayIcon() {
        guard trayAdded else { return }
        var nid = trayData()
        _ = Shell_NotifyIconW(2 /* NIM_DELETE */, &nid)
        trayAdded = false
    }

    private func showTrayMenu() {
        guard let hwnd, let menu = CreatePopupMenu() else { return }
        defer { _ = DestroyMenu(menu) }
        func item(_ id: Int, _ title: String) {
            _ = withWide(title) { AppendMenuW(menu, 0 /* MF_STRING */, UINT_PTR(id), $0) }
        }
        item(ID.trayOpen, "開く")
        item(ID.trayPair, "新しい端末を登録 (ペアリングコード)")
        item(ID.trayStartStop, service.isRunning ? "待ち受けを停止" : "待ち受けを開始")
        _ = AppendMenuW(menu, 0x800 /* MF_SEPARATOR */, 0, nil)
        item(ID.trayQuit, "終了")
        var pt = POINT()
        _ = GetCursorPos(&pt)
        _ = SetForegroundWindow(hwnd)
        // 選んだ項目は WM_COMMAND で届く
        _ = TrackPopupMenu(menu, 0x0002 /* TPM_RIGHTBUTTON */, pt.x, pt.y, 0, hwnd, nil)
        _ = PostMessageW(hwnd, 0 /* WM_NULL */, 0, 0)
    }

    private func showWindow() {
        guard let hwnd else { return }
        _ = ShowWindow(hwnd, 9 /* SW_RESTORE */)
        _ = ShowWindow(hwnd, 5)
        _ = SetForegroundWindow(hwnd)
    }

    private func quit() {
        quitting = true
        if let hwnd { _ = DestroyWindow(hwnd) }
    }

    private func handleCommand(_ id: Int) {
        switch id {
        case ID.startStop, ID.trayStartStop: toggleService()
        case ID.pair, ID.trayPair: pair()
        case ID.copyCode:
            if let p = service.pairing {
                copyToClipboard(p.code, owner: hwnd)
                flash("ペアリングコードをコピーしました")
            }
        case ID.copyEndpoint:
            if let e = service.directEndpoint {
                copyToClipboard(e, owner: hwnd)
                flash("接続先 (\(e)) をコピーしました")
            }
        case ID.revoke: revokeSelected()
        case ID.resetDevices: resetDevices()
        case ID.save: save()
        case ID.verifyLog: alert("監査ログ", HostService.verifyAuditLog(), warning: false)
        case ID.openFolder: openDataFolder()
        case ID.trayOpen: showWindow()
        case ID.trayQuit: quit()
        default: break
        }
    }

    // MARK: メッセージ

    func handle(_ h: HWND, _ msg: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT? {
        guard h == hwnd else { return nil }
        switch msg {
        case WM.paint:
            paint(h)
            return 0
        case WM.eraseBkgnd:
            return 1
        case WM.command:
            handleCommand(loword(w))
            return 0
        case WM.lButtonDown:
            let x = xFromLParam(l), y = yFromLParam(l)
            for i in 0 ..< navItems.count where contains(navRect(i), x, y) {
                setPage(i)
                return 0
            }
            return 0
        case WM.setCursor:
            var pt = POINT()
            _ = GetCursorPos(&pt)
            _ = ScreenToClient(h, &pt)
            if (0 ..< navItems.count).contains(where: { contains(navRect($0), pt.x, pt.y) }) {
                _ = SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32649 /* IDC_HAND */)))
                return 1
            }
            return nil
        case WM.timer:
            if service.pairing != nil || flashText != nil { _ = InvalidateRect(h, nil, false) }
            if flashText != nil && Date() > flashUntil { flashText = nil }
            if service.pairing == nil, let c = ctl(ID.copyCode), IsWindowVisible(c) { refresh() }
            return 0
        case WM.app + 1:
            refresh()
            if page == 1 { reloadDevices() }
            return 0
        case WM.app + 2:
            drainLog()
            return 0
        case WM.app + 3:
            switch UINT(l & 0xFFFF) {
            case WM.lButtonDblClk, WM.lButtonUp: showWindow()
            case WM.rButtonUp: showTrayMenu()
            default: break
            }
            return 0
        case WM.ctlColorStatic, WM.ctlColorBtn:
            // チェックボックスの背景をカードの白に
            if let dc = HDC(bitPattern: UInt(w)) {
                _ = SetBkColor(dc, Palette.card)
                _ = SetTextColor(dc, Palette.text)
            }
            return lresult(UnsafeMutableRawPointer(cardBrush))
        case WM.measureItem:
            if let mi = UnsafeMutablePointer<MEASUREITEMSTRUCT>(bitPattern: Int(l)) {
                mi.pointee.itemHeight = UINT(S(62))
            }
            return 1
        case WM.drawItem:
            guard let di = UnsafeMutablePointer<DRAWITEMSTRUCT>(bitPattern: Int(l)) else { return nil }
            if di.pointee.CtlType == 2 /* ODT_LISTBOX */ { drawDevice(di.pointee) } else { drawButton(di.pointee) }
            return 1
        case WM.close:
            if settings.closeToTray && trayAdded && !quitting {
                _ = ShowWindow(h, 0)
                if !toldAboutTray {
                    toldAboutTray = true
                    balloon("タスクトレイで動いています", "待ち受けは続いています。アイコンを右クリックすると終了できます。")
                }
                return 0
            }
            _ = DestroyWindow(h)
            return 0
        case WM.destroy:
            removeTrayIcon()
            PostQuitMessage(0)
            return 0
        default:
            return nil
        }
    }

    private func drainLog() {
        logLock.lock()
        let lines = pendingLog
        pendingLog.removeAll()
        logLock.unlock()
        guard let e = ctl(ID.log), !lines.isEmpty else { return }
        // 長くなりすぎたら古い分を捨てる
        if SendMessageW(e, Msg.emGetLineCount, 0, 0) > 3000 { setText(ID.log, "") }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        _ = SendMessageW(e, Msg.emSetSel, WPARAM(bitPattern: -1), -1)
        _ = withWide(text) { SendMessageW(e, Msg.emReplaceSel, 0, lparam(UnsafeMutableRawPointer(mutating: $0))) }
    }

    // MARK: 描画

    private func paint(_ h: HWND) {
        var ps = PAINTSTRUCT()
        guard let screen = BeginPaint(h, &ps) else { return }
        defer { _ = EndPaint(h, &ps) }
        var rc = RECT()
        _ = GetClientRect(h, &rc)
        guard let mem = CreateCompatibleDC(screen), let bmp = CreateCompatibleBitmap(screen, rc.right, rc.bottom) else { return }
        let old = SelectObject(mem, HGDIOBJ(bmp))
        let p = Painter(dc: mem)

        p.fill(rc, Palette.content)
        drawHeader(p, width: rc.right)
        drawSidebar(p, height: rc.bottom)
        switch page {
        case 0: drawHome(p)
        case 1: drawDevicesPage(p)
        case 2: drawSettingsPage(p)
        default: drawLogPage(p)
        }
        if let f = flashText {
            let w = p.measure(f, font: fBodyBold) + S(40)
            let r = makeRect((rc.right + S(sidebarW) - w) / 2, rc.bottom - S(48), w, S(34))
            p.roundRect(r, radius: S(34), fill: rgb(32, 34, 52))
            p.text(f, r, font: fBodyBold, color: rgb(255, 255, 255), flags: 0x1 | 0x20 | 0x4)
        }

        _ = BitBlt(screen, 0, 0, rc.right, rc.bottom, mem, 0, 0, 0x00CC_0020 /* SRCCOPY */)
        _ = SelectObject(mem, old)
        _ = DeleteObject(HGDIOBJ(bmp))
        _ = DeleteDC(mem)
    }

    private func drawHeader(_ p: Painter, width: Int32) {
        p.gradient(RECT(left: 0, top: 0, right: width, bottom: S(headerH)), [Palette.indigo, Palette.blue, Palette.cyan])
        p.icon(bigIcon, S(22), S(18), S(56))
        p.text("Remote Desktop ホスト", R(92, 16, 520, 36), font: fTitle, color: rgb(255, 255, 255))
        p.text("iPad / Mac から、この PC を安全に操作できるようにします", R(93, 52, 560, 24), font: fSubtitle,
               color: rgb(232, 238, 255))

        // 状態のバッジ
        let (label, dot) = statusLabel()
        let tw = p.measure(label, font: fBodyBold)
        let pw = tw + S(44)
        let pill = makeRect(width - pw - S(24), S(28), pw, S(36))
        p.roundRect(pill, radius: S(36), fill: rgb(255, 255, 255))
        p.circle(pill.left + S(20), pill.top + S(18), S(5), dot)
        p.text(label, RECT(left: pill.left + S(32), top: pill.top, right: pill.right, bottom: pill.bottom),
               font: fBodyBold, color: Palette.text)
    }

    private func statusLabel() -> (String, COLORREF) {
        if !service.isRunning { return ("停止中", Palette.gray) }
        let s = service.sessions
        if !s.isEmpty { return ("接続中 (\(s.count))", rgb(56, 112, 255)) }
        return ("待ち受け中", Palette.green)
    }

    private func drawSidebar(_ p: Painter, height: Int32) {
        p.fill(RECT(left: 0, top: S(headerH), right: S(sidebarW), bottom: height), Palette.sidebar)
        for (i, item) in navItems.enumerated() {
            let r = navRect(i)
            let selected = i == page
            if selected { p.gradient(r, [Palette.indigo, Palette.blue], radius: S(14)) }
            let color = selected ? Palette.navSelectedText : Palette.text
            p.text(item.glyph, RECT(left: r.left + S(14), top: r.top, right: r.left + S(44), bottom: r.bottom),
                   font: fIcon, color: color)
            p.text(item.title, RECT(left: r.left + S(48), top: r.top, right: r.right, bottom: r.bottom),
                   font: selected ? fBodyBold : fBody, color: color)
            if i == 1, !devices.isEmpty || !service.devices.isEmpty {
                let n = "\(service.devices.count)"
                let bw = p.measure(n, font: fSmall) + S(16)
                let b = makeRect(r.right - bw - S(12), r.top + S(12), bw, S(20))
                p.roundRect(b, radius: S(20), fill: selected ? rgb(255, 255, 255) : rgb(220, 224, 245))
                p.text(n, b, font: fSmall, color: selected ? Palette.brandText : Palette.text, flags: 0x1 | 0x20 | 0x4)
            }
        }
        // 下の説明
        p.text("\u{E72E}", R(20, clientH - 64, 20, 20), font: fIconSmall, color: Palette.sub)
        p.paragraph("端末間で暗号化 (Noise)・ペアリングした端末だけが接続できます", R(40, clientH - 66, sidebarW - 54, 56),
                    font: fSmall, color: Palette.sub)
    }

    private var contentX: Int { sidebarW + 24 }
    private var contentW: Int { clientW - sidebarW - 48 }

    private func card(_ p: Painter, y: Int, h: Int, title: String, glyph: String) {
        p.roundRect(R(contentX, y, contentW, h), radius: S(18), fill: Palette.card, border: Palette.border)
        let badge = R(contentX + 20, y + 18, 30, 30)
        p.gradient(badge, [Palette.indigo, Palette.blue], radius: S(10))
        p.text(glyph, badge, font: fIconSmall, color: rgb(255, 255, 255), flags: 0x1 | 0x20 | 0x4)
        p.text(title, R(contentX + 60, y + 18, contentW - 300, 30), font: fH2, color: Palette.text)
    }

    private func labelValue(_ p: Painter, _ label: String, _ value: String, y: Int, mono: Bool = false) {
        p.text(label, R(contentX + 24, y, 170, 24), font: fSmall, color: Palette.sub)
        p.text(value, R(contentX + 190, y, contentW - 420, 24), font: mono ? fMono : fBody, color: Palette.text)
    }

    private func drawHome(_ p: Painter) {
        // 待ち受け
        card(p, y: 112, h: 190, title: "待ち受け", glyph: "\u{E774}")
        let (label, dot) = statusLabel()
        p.circle(S(contentX + 32), S(76 + 96), S(7), dot)
        p.text(label, R(contentX + 48, 156, 300, 32), font: fStatus, color: Palette.text)
        let relay: String
        switch service.relayState {
        case .off: relay = settings.relayURL.isEmpty ? "使わない" : (service.isRunning ? "—" : settings.relayURL)
        case .connecting: relay = "接続しています… (\(settings.relayURL))"
        case .up(let t): relay = "接続済み・\(t) (\(settings.relayURL))"
        case .down(let r): relay = "つながっていません: \(r)"
        }
        var direct = settings.direct ? "—" : "使わない"
        if let e = service.directEndpoint {
            direct = e + (service.bonjourName.map { "  ・ iPad には「\($0)」と表示" } ?? "")
        }
        labelValue(p, "直接接続 (同じ Wi-Fi)", direct, y: 198)
        labelValue(p, "中継サーバー", relay, y: 224)
        labelValue(p, "この PC の指紋", service.fingerprint, y: 250, mono: true)
        if service.isTampered {
            p.text("⚠ 許可端末の一覧が改ざんされています。すべての接続を拒否します (端末 → すべて消去)",
                   R(contentX + 24, 274, contentW - 48, 22), font: fBodyBold, color: Palette.red)
        }

        // ペアリング
        card(p, y: 314, h: 150, title: "新しい端末を登録", glyph: "\u{E8D7}")
        if let pr = service.pairing {
            p.text(pr.code, R(contentX + 24, 358, contentW - 260, 44), font: fCode, color: Palette.brandText)
            let left = max(0, Int(pr.expires.timeIntervalSinceNow))
            p.text("残り \(left / 60):\(String(format: "%02d", left % 60))  ・  1 回限り  ・  他人に見せないでください",
                   R(contentX + 24, 406, contentW - 260, 24), font: fSmall, color: Palette.sub)
            p.text("iPad で「同じ Wi-Fi」を選び、この PC を選んでコードを入力してください", R(contentX + 24, 430, contentW - 260, 24),
                   font: fSmall, color: Palette.sub)
        } else {
            p.paragraph("iPad / Mac を同じ Wi-Fi につないで、ペアリングコードを入力すると登録できます。登録のときは、この PC の画面での許可が必要です。コードは 10 分間・1 回だけ有効です。",
                        R(contentX + 24, 360, contentW - 270, 90), font: fBody, color: Palette.sub)
        }

        // 接続中
        card(p, y: 476, h: 180, title: "接続中の端末", glyph: "\u{E7F4}")
        let sessions = service.sessions
        if sessions.isEmpty {
            p.text("いまは接続されていません", R(contentX + 24, 520, contentW - 48, 26), font: fBody, color: Palette.sub)
        } else {
            for (i, name) in sessions.prefix(3).enumerated() {
                p.circle(S(contentX + 32), S(533 + i * 28), S(5), rgb(56, 112, 255))
                p.text(name, R(contentX + 46, 520 + i * 28, contentW - 80, 26), font: fBodyBold, color: Palette.text)
            }
        }
        p.text(service.lastTraffic ?? "通信量: まだ送っていません", R(contentX + 24, 606, contentW - 48, 22), font: fSmall,
               color: Palette.sub)
        p.text("登録済みの端末: \(service.devices.count) 台", R(contentX + 24, 626, contentW - 48, 22), font: fSmall,
               color: Palette.sub)
    }

    private func drawDevicesPage(_ p: Painter) {
        card(p, y: 112, h: 482, title: "登録済みの端末 (\(devices.count) 台)", glyph: "\u{E8EA}")
        p.text("取り消した端末は接続できなくなります (接続中なら切断)。", R(contentX + 60, 146, contentW - 100, 22),
               font: fSmall, color: Palette.sub)
        if devices.isEmpty {
            p.text("まだ登録された端末はありません。ホームの「ペアリングコードを表示」から登録してください。",
                   R(contentX + 24, 300, contentW - 48, 26), font: fBody, color: Palette.sub, flags: 0x1 | 0x20 | 0x4)
        }
    }

    private func drawDevice(_ di: DRAWITEMSTRUCT) {
        guard let dc = di.hDC else { return }
        let p = Painter(dc: dc)
        let r = di.rcItem
        let selected = di.itemState & 0x1 != 0 // ODS_SELECTED
        p.fill(r, selected ? Palette.selection : Palette.card)
        p.fill(RECT(left: r.left + S(8), top: r.bottom - 1, right: r.right - S(8), bottom: r.bottom), Palette.border)
        let i = Int(di.itemID)
        guard i >= 0, i < devices.count else { return }
        let d = devices[i]
        let badge = RECT(left: r.left + S(10), top: r.top + S(12), right: r.left + S(48), bottom: r.top + S(50))
        p.gradient(badge, [Palette.indigo, Palette.cyan], radius: S(12))
        p.text("\u{E70A}", badge, font: fIcon, color: rgb(255, 255, 255), flags: 0x1 | 0x20 | 0x4)
        p.text(d.name, RECT(left: r.left + S(62), top: r.top + S(8), right: r.right - S(260), bottom: r.top + S(32)),
               font: fBodyBold, color: Palette.text)
        p.text(d.fingerprint, RECT(left: r.left + S(62), top: r.top + S(32), right: r.right - S(20), bottom: r.top + S(54)),
               font: fMono, color: Palette.sub)
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        let seen = d.lastSeen.map { "最終接続 \(relativeTime($0))" } ?? "まだ接続していません"
        p.text("登録 \(f.string(from: d.added))  ・  \(seen)",
               RECT(left: r.right - S(330), top: r.top + S(8), right: r.right - S(14), bottom: r.top + S(32)),
               font: fSmall, color: Palette.sub, flags: 0x2 | 0x20 | 0x4 | 0x8000)
    }

    private func drawSettingsPage(_ p: Painter) {
        card(p, y: 112, h: 556, title: "設定", glyph: "\u{E713}")
        p.text("保存すると、待ち受け中なら新しい設定で始め直します。", R(contentX + 60, 146, contentW - 260, 22),
               font: fSmall, color: Palette.sub)
        let labels = ["中継サーバーの URL", "中継の通り道", "直接接続", "Bonjour", "接続の確認", "切断したとき",
                      "無操作で切断", "画質", "送信量の上限", "耐量子暗号", "起動したとき", "閉じるボタン", "サインイン時"]
        for (i, l) in labels.enumerated() {
            p.text(l, R(contentX + 24, 168 + i * 34, 170, 26), font: fBodyBold, color: Palette.text)
        }
        let ctlX = contentX + 200
        p.text("ポート", R(ctlX + 350, 168 + 2 * 34, 56, 26), font: fSmall, color: Palette.sub)
        p.text("分", R(ctlX + 90, 168 + 6 * 34, 40, 26), font: fBody, color: Palette.sub)
        p.text("fps", R(ctlX + 90, 168 + 7 * 34, 50, 26), font: fBody, color: Palette.sub)
        p.text("kbps (0 = 無制限。無料の中継サーバーなら 500 程度)", R(ctlX + 110, 168 + 8 * 34, 380, 26), font: fSmall,
               color: Palette.sub)
    }

    private func drawLogPage(_ p: Painter) {
        card(p, y: 112, h: 486, title: "ログ", glyph: "\u{E8A5}")
        p.text("接続・認証・通信量の記録です。監査ログはハッシュの鎖で改ざんを検知できます。", R(contentX + 60, 140, contentW - 100, 22),
               font: fSmall, color: Palette.sub)
    }

    private func drawButton(_ di: DRAWITEMSTRUCT) {
        guard let dc = di.hDC else { return }
        let p = Painter(dc: dc)
        let id = Int(di.CtlID)
        let (kind, bg) = buttonKinds[id] ?? (.secondary, Palette.card)
        let r = di.rcItem
        p.fill(r, bg)
        let pressed = di.itemState & 0x1 != 0
        let disabled = di.itemState & 0x4 != 0
        let inner = RECT(left: r.left, top: r.top + (pressed ? 1 : 0), right: r.right, bottom: r.bottom + (pressed ? 1 : 0))
        var textColor = rgb(255, 255, 255)
        switch kind {
        case .primary:
            p.gradient(inner, pressed ? [Palette.indigo, Palette.indigo] : [Palette.indigo, Palette.blue], radius: S(14))
        case .danger:
            p.roundRect(inner, radius: S(14), fill: pressed ? rgb(190, 40, 50) : Palette.red)
        case .secondary:
            p.roundRect(inner, radius: S(14), fill: pressed ? rgb(222, 226, 242) : rgb(234, 237, 250), border: Palette.border)
            textColor = Palette.brandText
        }
        if disabled { textColor = Palette.gray }
        var buf = [WCHAR](repeating: 0, count: 128)
        let n = GetWindowTextW(di.hwndItem, &buf, 128)
        p.text(String(decoding: buf.prefix(Int(n)), as: UTF16.self), inner, font: fBodyBold, color: textColor,
               flags: 0x1 | 0x20 | 0x4)
    }

    // MARK: CI 用の画面確認

    func takeScreenshots(_ dir: String) {
        guard let hwnd else { return }
        _ = ShowWindow(hwnd, 5)
        appendLog("直接接続: 0.0.0.0:5999 で待ち受け中")
        appendLog("[監査] HOST_START direct=true relay=- confirm=false")
        appendLog("通信量: 直近 60 秒で 412 KB (平均 55 kbps) / 送信 37 回・タイル 可逆 120 粗い 64 高画質化 64")
        for i in 0 ..< navItems.count {
            setPage(i)
            pump(0.5)
            let ok = saveWindowBitmap(hwnd, to: dir + "\\host-\(i).bmp")
            print("screenshot page \(i): \(ok)")
        }
    }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        var msg = MSG()
        while Date() < end {
            while PeekMessageW(&msg, nil, 0, 0, 0x1 /* PM_REMOVE */) {
                _ = TranslateMessage(&msg)
                _ = DispatchMessageW(&msg)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

// MARK: - 起動

func runApp() {
    let args = CommandLine.arguments
    var screenshotDir: String?
    if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
        screenshotDir = args[i + 1]
        try? FileManager.default.createDirectory(atPath: args[i + 1], withIntermediateDirectories: true)
        DataDirectory.overridePath = args[i + 1] + "\\data"
    }
    if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count { DataDirectory.overridePath = args[i + 1] }

    HostService.setupPlatform()
    enableVisualStyles()

    // 2 つ目の起動なら、動いている方のウィンドウを出して終わる
    if screenshotDir == nil {
        _ = withWide("Local\\RemoteDesktopHost") { CreateMutexW(nil, false, $0) }
        if GetLastError() == 183 /* ERROR_ALREADY_EXISTS */ {
            if let other = withWide("RemoteDesktopHostWindow", { FindWindowW($0, nil) }) {
                _ = ShowWindow(other, 9)
                _ = SetForegroundWindow(other)
            }
            return
        }
    }

    func fail(_ title: String, _ text: String) {
        _ = withWide(text) { t in withWide(title) { c in MessageBoxW(nil, t, c, 0x10 /* MB_ICONERROR */) } }
    }
    // 画面確認モードは CI (SYSTEM 権限) で動かすので、確認のダイアログは出さない (出すと誰も閉じられず止まる)
    if screenshotDir == nil, let problem = HostService.environmentProblem(allowAdmin: args.contains("--allow-admin")) {
        fail("Remote Desktop ホスト", problem)
        return
    }
    let settings = HostSettings.load()
    RelayTransportMode.default = RelayTransportMode(rawValue: settings.relayTransport) ?? .auto
    let service: HostService
    do {
        service = try HostService(options: settings.options)
    } catch {
        fail("Remote Desktop ホスト", "鍵を読み込めません: \(error)")
        return
    }
    let window = HostWindow(service: service, settings: settings)
    window.create(show: screenshotDir != nil || !args.contains("--minimized"))
    if let dir = screenshotDir {
        _ = service.startPairing() // コードの表示も確認する
        window.refresh()
        window.takeScreenshots(dir)
        return
    }
    if settings.autoStart { window.startService() }

    var msg = MSG()
    while GetMessageW(&msg, nil, 0, 0) {
        _ = TranslateMessage(&msg)
        _ = DispatchMessageW(&msg)
    }
}
#endif

#if os(Windows)
/// 「3 分前」などの表記
func relativeTime(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "たった今" }
    if s < 3600 { return "\(s / 60) 分前" }
    if s < 86400 { return "\(s / 3600) 時間前" }
    return "\(s / 86400) 日前"
}
#endif
