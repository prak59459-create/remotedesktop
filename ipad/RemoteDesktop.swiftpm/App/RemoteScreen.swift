import SwiftUI
import UIKit

/// リモート画面 + 操作用ツールバー
struct RemoteScreenContainer: View {
    @ObservedObject var session: ViewerSession
    @State private var showText = false
    @State private var showHelp = false
    @State private var text = ""
    @StateObject private var controller = RemoteViewController()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            RemoteViewRepresentable(session: session, controller: controller)
                .ignoresSafeArea()
            toolbar
        }
        .statusBar(hidden: true)
        .sheet(isPresented: $showText) {
            NavigationView {
                Form {
                    Section(footer: Text("日本語などはここで入力して確定すると、そのまま Windows に入力されます。")) {
                        TextField("送る文字", text: $text, onCommit: sendText)
                    }
                    Button("送信", action: sendText)
                    Button("送信して Enter") {
                        sendText()
                        controller.tap([.scancode(0x1C)])
                    }
                }
                .navigationTitle("文字入力")
                .toolbar { Button("閉じる") { showText = false } }
            }
        }
        .sheet(isPresented: $showHelp) { GestureHelp { showHelp = false } }
        #if RD_SCREENSHOTS
        .onReceive(ScreenshotDriver.shared.showTextSheet) { t in
            text = t
            showText = !t.isEmpty
        }
        .onReceive(ScreenshotDriver.shared.toggleKeyboard) { controller.toggleKeyboard() }
        #endif
    }

    private func sendText() {
        if !text.isEmpty { session.send(.text(text)) }
        text = ""
        showText = false
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { controller.toggleKeyboard() } label: { Image(systemName: "keyboard") }
            Button { showText = true } label: { Image(systemName: "character.cursor.ibeam") }
            Button("Esc") { controller.tap([.scancode(0x01)]) }
            Button("Tab") { controller.tap([.scancode(0x0F)]) }
            Button("Win") { controller.tap([.scancode(0xE05B)]) }
            Button("Alt+Tab") { controller.tap([.scancode(0x38), .scancode(0x0F)]) }
            if controller.zoomed {
                Button { controller.resetZoom() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
            }
            Spacer()
            Button { showHelp = true } label: { Image(systemName: "hand.tap") }
            Text("🔒").help("\(session.securitySummary)\n\(session.hostFingerprint)")
            Button(role: .destructive) { session.disconnect() } label: { Image(systemName: "xmark.circle.fill") }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 4)
        .padding(.horizontal, 8)
    }
}

/// 操作方法の一覧
struct GestureHelp: View {
    let close: () -> Void

    private struct Row: Identifiable {
        let gesture: String
        let action: String
        var id: String { gesture }
        init(_ g: String, _ a: String) { gesture = g; action = a }
    }

    private let finger: [Row] = [
        Row("1 本指でなぞる", "カーソル移動"),
        Row("1 本指でタップ", "左クリック (2 回でダブルクリック)"),
        Row("2 本指でタップ", "右クリック"),
        Row("3 本指でタップ", "中クリック"),
        Row("2 本指で動かす", "スクロール"),
        Row("長押ししてから動かす", "ドラッグ (範囲選択・ウィンドウの移動)"),
        Row("ピンチ", "表示の拡大・縮小 (拡大中はカーソルを追って動く)"),
    ]
    private let pointer: [Row] = [
        Row("動かす", "カーソルがポインタの位置に"),
        Row("クリック / 副ボタン", "左クリック / 右クリック"),
        Row("押したまま動かす", "ドラッグ"),
        Row("ホイール / 2 本指", "スクロール"),
    ]

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("指で (トラックパッドのように)")) {
                    ForEach(finger) { row($0) }
                }
                Section(header: Text("マウス / トラックパッドをつないだとき")) {
                    ForEach(pointer) { row($0) }
                }
            }
            .navigationTitle("操作方法")
            .toolbar { Button("閉じる", action: close) }
        }
    }

    private func row(_ r: Row) -> some View {
        HStack {
            Text(r.gesture).bold()
            Spacer()
            Text(r.action).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// SwiftUI から UIView を操作するための橋渡し
final class RemoteViewController: ObservableObject {
    weak var view: RemoteUIView? {
        didSet {
            view?.onZoomChange = { [weak self] z in
                DispatchQueue.main.async { self?.zoomed = z > 1 } // SwiftUI の描画中に変更しない
            }
        }
    }
    @Published var zoomed = false
    func toggleKeyboard() { view?.toggleKeyboard() }
    func tap(_ keys: [RemoteKey]) { view?.tap(keys) }
    func resetZoom() { view?.resetZoom() }
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
        let k = pixelsPerPoint * 1.4
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
        scrollAccum.x += -t.x * 3
        scrollAccum.y += t.y * 3
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
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            session.send(.mouseButton(.left, down: true))
        case .changed:
            moveCursor(by: CGPoint(x: p.x - lastLongPress.x, y: p.y - lastLongPress.y))
            lastLongPress = p
        default:
            session.send(.mouseButton(.left, down: false))
        }
    }

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
        session.send(.mouseButton(b, down: true))
        session.send(.mouseButton(b, down: false))
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
