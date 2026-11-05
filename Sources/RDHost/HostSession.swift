import Dispatch
import Foundation
import RDCore

struct HostOptions {
    var port: UInt16 = defaultPort
    var bindAddress: String?
    var fps: Double = 30
    var scale: Int = 1
    var pair = false
    var confirm = false
    var relay: URL?
    var direct = true
    var allowRemotePairing = false
    /// 入力が無いまま、この秒数が過ぎたら切断する
    var idleTimeout: TimeInterval = 15 * 60
    /// 1 回のセッションの最長時間 (秒)
    var maxSession: TimeInterval = 8 * 3600
    var onDisconnect = DisconnectAction.blank
    var requirePostQuantum = false
    var allowAdmin = false
}

/// 接続中のセッション。画面上部の「接続中」表示と、最後の切断時の画面保護を受け持つ。
final class ActiveSessions {
    static let shared = ActiveSessions()
    private let lock = NSLock()
    private var names: [Int: String] = [:]
    private var nextID = 0
    var onDisconnect = DisconnectAction.blank

    func begin(_ name: String) -> Int {
        lock.lock()
        nextID += 1
        let id = nextID
        names[id] = name
        let text = label()
        lock.unlock()
        showConnectionIndicator(text)
        return id
    }

    func end(_ id: Int) {
        lock.lock()
        names[id] = nil
        let empty = names.isEmpty
        let text = label()
        lock.unlock()
        if empty {
            showConnectionIndicator(nil)
            performDisconnectAction(onDisconnect)
        } else {
            showConnectionIndicator(text)
        }
    }

    private func label() -> String {
        let list = names.values.sorted().joined(separator: "、")
        return "リモート操作中: \(list)"
    }
}

/// 認証済みの 1 つのビューア接続を担当する。画面送信ループと入力受信スレッドを持つ。
final class HostSession {
    private let channel: MessageChannel
    private let client: HostGatekeeper.Client
    private let audit: AuditLog
    private let options: HostOptions
    private let injector = makeInjector()
    private let ackSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var closed = false
    private var keyframeRequested = false
    private var lastInput = Date()
    private let started = Date()
    // 入力座標の変換用 (フレーム座標 → 実画面座標)
    private var mapping = (frameW: 1, frameH: 1, screenW: 1, screenH: 1)

    private let gate: HostGatekeeper

    init(client: HostGatekeeper.Client, gate: HostGatekeeper, options: HostOptions, audit: AuditLog) {
        self.client = client
        self.gate = gate
        channel = client.channel
        self.options = options
        self.audit = audit
    }

    private var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    private func markClosed() {
        stateLock.lock()
        closed = true
        stateLock.unlock()
        channel.close()
        ackSemaphore.signal()
    }

    private func takeKeyframeRequest() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        let r = keyframeRequested
        keyframeRequested = false
        return r
    }

    func run() {
        let token = ActiveSessions.shared.begin(client.name)
        let receiver = Thread { [self] in receiveLoop() }
        receiver.start()
        let reason = sendLoop()
        markClosed()
        audit.record("SESSION_END name=\(client.name) peer=\(client.peer) reason=\(reason)")
        ActiveSessions.shared.end(token)
    }

    /// 無操作・最長時間を超えていれば理由を返す
    private func expired(now: Date) -> String? {
        stateLock.lock()
        let idle = now.timeIntervalSince(lastInput)
        stateLock.unlock()
        if idle > options.idleTimeout { return "idle_timeout" }
        if now.timeIntervalSince(started) > options.maxSession { return "max_session" }
        return nil
    }

    // MARK: 画面送信

    /// 終了理由を返す
    private func sendLoop() -> String {
        let interval = 1.0 / max(1, options.fps)
        var lastAuthCheck = Date()
        while !isClosed {
            guard let capturer = makeCapturer(scale: options.scale) else {
                print("画面キャプチャを初期化できません。1 秒後に再試行します")
                Thread.sleep(forTimeInterval: 1)
                if let r = expired(now: Date()) { return r }
                continue
            }
            stateLock.lock()
            mapping = (capturer.width, capturer.height, capturer.screenWidth, capturer.screenHeight)
            stateLock.unlock()
            print("画面 \(capturer.screenWidth)x\(capturer.screenHeight) → 送信 \(capturer.width)x\(capturer.height)")

            do {
                try channel.send(.hello, Hello(width: capturer.width, height: capturer.height).encode())
            } catch {
                return "disconnected"
            }
            let encoder = FrameEncoder(width: capturer.width, height: capturer.height)

            while !isClosed {
                let start = Date()
                if start.timeIntervalSince(lastAuthCheck) > 2 {
                    lastAuthCheck = start
                    if !gate.isStillAuthorized(client.publicKey) {
                        audit.record("SESSION_KILLED reason=device_revoked name=\(client.name) peer=\(client.peer)")
                        return "device_revoked"
                    }
                    if let r = expired(now: start) { return r }
                }
                if capturer.needsRecreate { break } // 解像度変更 → hello から送り直す
                if takeKeyframeRequest() { encoder.reset() }

                if let image = capturer.capture(),
                   let payload = encoder.encode(image, srcStride: capturer.bytesPerRow) {
                    do {
                        try channel.send(.frame, payload)
                    } catch {
                        return "disconnected"
                    }
                    // ビューアが処理し終えるまで次を送らない (遅い回線で溜まらないように)
                    _ = ackSemaphore.wait(timeout: .now() + 5)
                }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < interval { Thread.sleep(forTimeInterval: interval - elapsed) }
            }
        }
        return "disconnected"
    }

    // MARK: 入力受信

    private func receiveLoop() {
        defer { markClosed() }
        do {
            while true {
                let (type, payload) = try channel.receive()
                guard let event = try ClientEvent.decode(type: type, payload: payload) else { continue }
                handle(event)
            }
        } catch {
            // 切断
        }
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .frameAck, .requestKeyframe:
            break
        default:
            stateLock.lock(); lastInput = Date(); stateLock.unlock()
        }
        switch event {
        case .frameAck:
            ackSemaphore.signal()
        case .requestKeyframe:
            stateLock.lock()
            keyframeRequested = true
            stateLock.unlock()
        case let .mouseMove(x, y):
            stateLock.lock()
            let m = mapping
            stateLock.unlock()
            let fx = min(max(Int(x), 0), m.frameW - 1)
            let fy = min(max(Int(y), 0), m.frameH - 1)
            injector.moveMouse(x: fx * m.screenW / m.frameW, y: fy * m.screenH / m.frameH)
        case let .mouseButton(button, down):
            injector.mouseButton(Int(button.rawValue), down: down)
        case let .mouseWheel(dx, dy):
            injector.wheel(dx: dx, dy: dy)
        case let .key(code, down, vk):
            injector.key(code: code, down: down, virtualKey: vk)
        case let .text(s):
            injector.text(s)
        }
    }
}
