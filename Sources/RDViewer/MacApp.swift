#if os(macOS)
import AppKit
import RDCore

func runMacApp(_ arguments: [String]) -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate(arguments: arguments)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}

// MARK: - アプリ

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    private var connectWindow: ConnectWindowController?
    private var sessions: [SessionWindowController] = []

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        // 引数で host [port] が指定されていればすぐ接続
        let positional = arguments.filter { !$0.hasPrefix("-") }
        if let host = positional.first {
            let port = positional.count > 1 ? UInt16(positional[1]) ?? defaultPort : defaultPort
            openSession(host: host, port: port, commandAsControl: true)
        } else {
            showConnectWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func showConnectWindow() {
        if connectWindow == nil {
            connectWindow = ConnectWindowController { [weak self] host, port, cmdAsCtrl in
                self?.openSession(host: host, port: port, commandAsControl: cmdAsCtrl)
            }
        }
        connectWindow?.showWindow(nil)
        connectWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func openSession(host: String, port: UInt16, commandAsControl: Bool) {
        let s = SessionWindowController(host: host, port: port, commandAsControl: commandAsControl)
        s.onClosed = { [weak self, weak s] in
            self?.sessions.removeAll { $0 === s }
        }
        sessions.append(s)
        s.start()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "新しい接続…", action: #selector(showConnectWindow), keyEquivalent: "n")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "RDViewer を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let remoteItem = NSMenuItem()
        main.addItem(remoteItem)
        let remoteMenu = NSMenu(title: "リモート")
        remoteMenu.addItem(withTitle: "Windows キーを送信", action: #selector(SessionWindowController.sendWindowsKey), keyEquivalent: "")
        remoteMenu.addItem(withTitle: "Ctrl+Shift+Esc (タスクマネージャー)", action: #selector(SessionWindowController.sendTaskManager), keyEquivalent: "")
        remoteMenu.addItem(withTitle: "Alt+Tab", action: #selector(SessionWindowController.sendAltTab), keyEquivalent: "")
        remoteMenu.addItem(withTitle: "画面を再取得", action: #selector(SessionWindowController.requestKeyframe), keyEquivalent: "")
        remoteMenu.addItem(.separator())
        remoteMenu.addItem(withTitle: "実寸表示", action: #selector(SessionWindowController.actualSize), keyEquivalent: "")
        remoteItem.submenu = remoteMenu
        NSApp.mainMenu = main
    }
}

// MARK: - 接続ダイアログ

final class ConnectWindowController: NSWindowController {
    private let hostField = NSTextField(string: UserDefaults.standard.string(forKey: "lastHost") ?? "")
    private let portField = NSTextField(string: UserDefaults.standard.string(forKey: "lastPort") ?? String(defaultPort))
    private let cmdCheck = NSButton(checkboxWithTitle: "⌘ を Ctrl として送る (オフなら Windows キー)", target: nil, action: nil)
    private let onConnect: (String, UInt16, Bool) -> Void

    init(onConnect: @escaping (String, UInt16, Bool) -> Void) {
        self.onConnect = onConnect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Windows に接続"
        super.init(window: window)
        window.isReleasedWhenClosed = false

        hostField.placeholderString = "192.168.0.10"
        portField.placeholderString = String(defaultPort)
        cmdCheck.state = UserDefaults.standard.object(forKey: "cmdAsCtrl") as? Bool == false ? .off : .on

        let connect = NSButton(title: "接続", target: self, action: #selector(connectPressed))
        connect.keyEquivalent = "\r"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "ホスト:"), hostField],
            [NSTextField(labelWithString: "ポート:"), portField],
            [NSGridCell.emptyContentView, cmdCheck],
            [NSGridCell.emptyContentView, connect],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        grid.rowSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func connectPressed() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { NSSound.beep(); return }
        let port = UInt16(portField.stringValue) ?? defaultPort
        let cmdAsCtrl = cmdCheck.state == .on
        UserDefaults.standard.set(host, forKey: "lastHost")
        UserDefaults.standard.set(String(port), forKey: "lastPort")
        UserDefaults.standard.set(cmdAsCtrl, forKey: "cmdAsCtrl")
        window?.orderOut(nil)
        onConnect(host, port, cmdAsCtrl)
    }
}

// MARK: - リモート画面ウィンドウ

final class SessionWindowController: NSWindowController, NSWindowDelegate {
    private let client: ViewerClient
    private let remoteView: RemoteView
    var onClosed: (() -> Void)?
    private var didSizeWindow = false

    init(host: String, port: UInt16, commandAsControl: Bool) {
        client = ViewerClient(host: host, port: port)
        remoteView = RemoteView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        remoteView.commandAsControl = commandAsControl
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(host):\(port) — 接続中…"
        window.contentView = remoteView
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        remoteView.client = client
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(remoteView)

        client.onHello = { [weak self] w, h in
            DispatchQueue.main.async { self?.handleHello(width: w, height: h) }
        }
        client.onFrame = { [weak self] fb in
            // 受信スレッドで CGImage を作ってからメインスレッドで表示
            guard let image = makeImage(fb) else { return }
            DispatchQueue.main.async { self?.remoteView.show(image) }
        }
        client.onClose = { [weak self] err in
            DispatchQueue.main.async { self?.handleDisconnect(err) }
        }

        let c = client
        DispatchQueue.global().async { [weak self] in
            do {
                try c.connect()
            } catch {
                DispatchQueue.main.async { self?.handleDisconnect(error) }
            }
        }
    }

    private func handleHello(width: Int, height: Int) {
        remoteView.remoteSize = CGSize(width: width, height: height)
        window?.title = "\(client.host):\(client.port) — \(width)x\(height)"
        window?.contentAspectRatio = NSSize(width: width, height: height)
        if !didSizeWindow, let screen = window?.screen ?? NSScreen.main {
            didSizeWindow = true
            let avail = screen.visibleFrame.size
            let scale = min(1, avail.width * 0.9 / CGFloat(width), avail.height * 0.9 / CGFloat(height))
            window?.setContentSize(NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale))
            window?.center()
        }
    }

    private func handleDisconnect(_ error: Error?) {
        guard let window = window, window.isVisible else { return }
        window.title = "\(client.host):\(client.port) — 切断"
        remoteView.releaseAllKeys()
        let alert = NSAlert()
        alert.messageText = "接続が終了しました"
        alert.informativeText = error.map { "\($0)" } ?? "ホスト側で切断されました。"
        alert.beginSheetModal(for: window) { _ in window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        remoteView.releaseAllKeys()
        client.disconnect()
        onClosed?()
    }

    func windowDidResignKey(_ notification: Notification) {
        remoteView.releaseAllKeys()
    }

    // メニューから
    @objc func sendWindowsKey() { remoteView.tap([.scancode(0xE05B)]) }
    @objc func sendTaskManager() { remoteView.tap([.scancode(0x1D), .scancode(0x2A), .scancode(0x01)]) }
    @objc func sendAltTab() { remoteView.tap([.scancode(0x38), .scancode(0x0F)]) }
    @objc func requestKeyframe() { client.send(.requestKeyframe) }
    @objc func actualSize() {
        guard let s = remoteView.remoteSize, let screen = window?.screen else { return }
        let f = screen.backingScaleFactor
        window?.setContentSize(NSSize(width: s.width / f, height: s.height / f))
    }
}

private func makeImage(_ fb: Framebuffer) -> CGImage? {
    guard fb.width > 0, fb.height > 0 else { return nil }
    let data = fb.pixels.withUnsafeBytes { CFDataCreate(nil, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    guard let d = data, let provider = CGDataProvider(data: d) else { return nil }
    // メモリ上 B,G,R,A = 32bit リトルエンディアンの ARGB
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(width: fb.width, height: fb.height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: fb.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// MARK: - 画面表示と入力取得

final class RemoteView: NSView {
    weak var client: ViewerClient?
    var commandAsControl = true
    var remoteSize: CGSize?
    private var pressed: [UInt16: RemoteKey] = [:] // mac keyCode → 送信済みキー
    private var keyMonitor: Any?
    private var scrollAccum = CGPoint.zero
    private var lastMouse: (Int32, Int32)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        if keyMonitor == nil {
            // keyDown/keyUp/flagsChanged をアプリ内で横取りする (⌘ 併用時の keyUp 欠落対策)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
                guard let self = self, e.window === self.window, self.window?.isKeyWindow == true else { return e }
                return self.handleKey(e) ? nil : e
            }
        }
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: マウス

    /// ビュー座標 → リモート画面のピクセル座標
    private func remotePoint(_ event: NSEvent) -> (Int32, Int32)? {
        guard let size = remoteSize, size.width > 0, size.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        let ox = (bounds.width - w) / 2, oy = (bounds.height - h) / 2
        let x = ((p.x - ox) / scale).rounded(.down)
        let y = ((p.y - oy) / scale).rounded(.down)
        return (Int32(max(0, min(size.width - 1, x))), Int32(max(0, min(size.height - 1, y))))
    }

    private func sendMove(_ event: NSEvent) {
        guard let pt = remotePoint(event) else { return }
        if let last = lastMouse, last == pt { return }
        lastMouse = pt
        client?.send(.mouseMove(x: pt.0, y: pt.1))
    }

    private func button(_ event: NSEvent, _ b: MouseButton, down: Bool) {
        sendMove(event)
        client?.send(.mouseButton(b, down: down))
    }

    private func otherButton(_ event: NSEvent) -> MouseButton {
        switch event.buttonNumber {
        case 3: return .x1
        case 4: return .x2
        default: return .middle
        }
    }

    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(event, .left, down: true)
    }
    override func mouseUp(with event: NSEvent) { button(event, .left, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, .right, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, .right, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, otherButton(event), down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, otherButton(event), down: false) }

    override func scrollWheel(with event: NSEvent) {
        sendMove(event)
        // Windows は 1 ノッチ = 120。トラックパッドはピクセル単位なので 40px ≒ 1 ノッチ
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 3 : 120
        scrollAccum.x += -event.scrollingDeltaX * factor // Windows の HWHEEL は右が正
        scrollAccum.y += event.scrollingDeltaY * factor
        let dx = Int32(scrollAccum.x.rounded(.towardZero))
        let dy = Int32(scrollAccum.y.rounded(.towardZero))
        scrollAccum.x -= CGFloat(dx)
        scrollAccum.y -= CGFloat(dy)
        if dx != 0 || dy != 0 { client?.send(.mouseWheel(dx: dx, dy: dy)) }
    }

    // MARK: キーボード

    /// 処理したら true (イベントを飲み込む)
    private func handleKey(_ e: NSEvent) -> Bool {
        let code = e.keyCode
        switch e.type {
        case .keyDown:
            // ⌘Q と ⌘N はローカルで使う
            if e.modifierFlags.contains(.command),
               let ch = e.charactersIgnoringModifiers?.lowercased(), ch == "q" || ch == "n" {
                return false
            }
            guard let k = KeyMap.remoteKey(forMacKeyCode: code, commandAsControl: commandAsControl) else { return true }
            pressed[code] = k
            client?.send(k.event(down: true))
            return true
        case .keyUp:
            if let k = pressed.removeValue(forKey: code) {
                client?.send(k.event(down: false))
            }
            return true
        case .flagsChanged:
            if code == 0x39 { // CapsLock: 押すたびに状態が切り替わるので down+up を送る
                tap([.scancode(0x3A)])
                return true
            }
            guard let mask = KeyMap.modifierDeviceMask[code],
                  let k = KeyMap.remoteKey(forMacKeyCode: code, commandAsControl: commandAsControl) else { return true }
            let isDown = e.modifierFlags.rawValue & mask != 0
            if isDown {
                pressed[code] = k
                client?.send(k.event(down: true))
            } else if pressed.removeValue(forKey: code) != nil {
                client?.send(k.event(down: false))
            }
            return true
        default:
            return false
        }
    }

    /// 押しっぱなしのキーを全部離す (フォーカスを失ったとき等)
    func releaseAllKeys() {
        for (_, k) in pressed { client?.send(k.event(down: false)) }
        pressed.removeAll()
    }

    /// キーを順に押して逆順に離す
    func tap(_ keys: [RemoteKey]) {
        for k in keys { client?.send(k.event(down: true)) }
        for k in keys.reversed() { client?.send(k.event(down: false)) }
    }
}
#endif
