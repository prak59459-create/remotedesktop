import SwiftUI
import UIKit

/// リモート画面 + 操作用ツールバー
struct RemoteScreenContainer: View {
    @ObservedObject var session: ViewerSession
    @State private var showText = false
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
            Spacer()
            Text("🔒").help(session.hostFingerprint)
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

/// SwiftUI から UIView を操作するための橋渡し
final class RemoteViewController: ObservableObject {
    weak var view: RemoteUIView?
    func toggleKeyboard() { view?.toggleKeyboard() }
    func tap(_ keys: [RemoteKey]) { view?.tap(keys) }
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
/// 操作はトラックパッド方式: 1 本指で動かすとカーソル移動、タップで左クリック、
/// 2 本指タップで右クリック、2 本指で上下に動かすとスクロール、長押ししてから動かすとドラッグ。
final class RemoteUIView: UIView, UIKeyInput {
    private let session: ViewerSession
    private let imageLayer = CALayer()
    private let cursorLayer = CAShapeLayer()
    private var cursor = CGPoint.zero // リモート画面のピクセル座標
    private var pressed: [UIKeyboardHIDUsage: RemoteKey] = [:]
    private var scrollAccum = CGPoint.zero
    private var lastLongPress = CGPoint.zero
    private var keyboardVisible = false

    var remoteSize = CGSize.zero {
        didSet {
            guard remoteSize != oldValue else { return }
            cursor = CGPoint(x: remoteSize.width / 2, y: remoteSize.height / 2)
            setNeedsLayout()
        }
    }

    init(session: ViewerSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        imageLayer.contentsGravity = .resizeAspect
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        updateCursorLayer()
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() } // ハードウェアキーボードを受け取る
    }

    // MARK: 座標

    private var videoRect: CGRect {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return bounds }
        let s = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
        let w = remoteSize.width * s, h = remoteSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private var pixelsPerPoint: CGFloat {
        let r = videoRect
        return r.width > 0 ? remoteSize.width / r.width : 1
    }

    private func updateCursorLayer() {
        let r = videoRect
        guard remoteSize.width > 0 else { cursorLayer.isHidden = true; return }
        cursorLayer.isHidden = false
        cursorLayer.position = CGPoint(x: r.minX + cursor.x / pixelsPerPoint, y: r.minY + cursor.y / pixelsPerPoint)
    }

    private func moveCursor(to p: CGPoint) {
        guard remoteSize.width > 0 else { return }
        cursor.x = min(max(0, p.x), remoteSize.width - 1)
        cursor.y = min(max(0, p.y), remoteSize.height - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateCursorLayer()
        CATransaction.commit()
        session.send(.mouseMove(x: Int32(cursor.x), y: Int32(cursor.y)))
    }

    private func moveCursor(by delta: CGPoint) {
        // 指の移動量を画面の拡大率に合わせて、少し加速する
        let k = pixelsPerPoint * 1.4
        moveCursor(to: CGPoint(x: cursor.x + delta.x * k, y: cursor.y + delta.y * k))
    }

    private func viewToRemote(_ p: CGPoint) -> CGPoint {
        let r = videoRect
        return CGPoint(x: (p.x - r.minX) * pixelsPerPoint, y: (p.y - r.minY) * pixelsPerPoint)
    }

    // MARK: ジェスチャー

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = []
        addGestureRecognizer(pan)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all // マウスホイール / トラックパッドのスクロールも
        addGestureRecognizer(scroll)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.numberOfTouchesRequired = 1
        addGestureRecognizer(tap)

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onRightClick(_:)))
        twoTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoTap)

        let secondary = UITapGestureRecognizer(target: self, action: #selector(onRightClick(_:)))
        secondary.buttonMaskRequired = .secondary // マウスの右ボタン
        addGestureRecognizer(secondary)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        long.minimumPressDuration = 0.35
        addGestureRecognizer(long)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover) // マウス / トラックパッド接続時はポインタ位置に追従
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        moveCursor(by: t)
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        scrollAccum.x += -t.x * 3
        scrollAccum.y += t.y * 3
        let dx = Int32(scrollAccum.x.rounded(.towardZero)), dy = Int32(scrollAccum.y.rounded(.towardZero))
        scrollAccum.x -= CGFloat(dx)
        scrollAccum.y -= CGFloat(dy)
        if dx != 0 || dy != 0 { session.send(.mouseWheel(dx: dx, dy: dy)) }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        click(.left)
    }

    @objc private func onRightClick(_ g: UITapGestureRecognizer) {
        click(.right)
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

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .changed || g.state == .began else { return }
        moveCursor(to: viewToRemote(g.location(in: self)))
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
