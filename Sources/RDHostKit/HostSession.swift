import Dispatch
import Foundation
import RDCore

public struct HostOptions {
    public var port: UInt16 = defaultPort
    public var bindAddress: String?
    public var fps: Double = 30
    public var scale: Int = 1
    public var pair = false
    public var confirm = false
    public var relay: URL?
    public var direct = true
    /// 同じ LAN の iPad から見つけられるよう、Bonjour (DNS-SD) で PC の名前とポートを知らせる
    public var bonjour = true
    public var allowRemotePairing = false
    /// 入力が無いまま、この秒数が過ぎたら切断する
    public var idleTimeout: TimeInterval = 15 * 60
    /// 1 回のセッションの最長時間 (秒)
    public var maxSession: TimeInterval = 8 * 3600
    public var onDisconnect = DisconnectAction.blank
    public var requirePostQuantum = false
    public var allowAdmin = false
    /// 画面データの送信量の上限 (kbps)。0 で無制限。無料の中継サーバーの月間転送量を守るため
    public var maxKbps: Double = 0
    /// 通信量をこの秒数ごとに表示する。0 で表示しない
    public var statsInterval: TimeInterval = 60

    public init() {}
}

/// ホストの表示用メッセージの出口。コマンドライン版は標準出力、GUI 版はウィンドウのログ欄へ
public enum HostLog {
    private static let lock = NSLock()
    private static var _sink: (String) -> Void = { print($0) }

    public static var sink: (String) -> Void {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }
}

func hostLog(_ line: String) { HostLog.sink(line) }

/// 接続中のセッション。画面上部の「接続中」表示と、最後の切断時の画面保護を受け持つ。
final class ActiveSessions {
    static let shared = ActiveSessions()
    private let lock = NSLock()
    private var names: [Int: String] = [:]
    private var nextID = 0
    var onDisconnect = DisconnectAction.blank
    /// 接続が増えた・減ったとき (GUI の表示更新用)
    var onChange: (() -> Void)?

    /// 接続中の端末の名前
    var current: [String] {
        lock.lock(); defer { lock.unlock() }
        return names.values.sorted()
    }

    func begin(_ name: String) -> Int {
        lock.lock()
        nextID += 1
        let id = nextID
        names[id] = name
        let text = label()
        lock.unlock()
        showConnectionIndicator(text)
        onChange?()
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
        onChange?()
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
    /// ビューアが frame2 (通信量の少ない形式) を受け取れる
    private var viewerSupportsFrame2 = false
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

    private var frameFormat: FrameFormat {
        stateLock.lock(); defer { stateLock.unlock() }
        return viewerSupportsFrame2 ? .v2 : .v1
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
        audit.record("SESSION_END name=\(client.name) peer=\(client.peer) reason=\(reason) sent_kb=\(totalSent / 1024)")
        hostLog("通信量: このセッションで計 \(formatBytes(totalSent)) を送信しました")
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

    /// このセッションで送った画面データのバイト数
    private var totalSent = 0

    /// 終了理由を返す
    private func sendLoop() -> String {
        let interval = 1.0 / max(1, options.fps)
        var lastAuthCheck = Date()
        while !isClosed {
            guard let capturer = makeCapturer(scale: options.scale) else {
                hostLog("画面キャプチャを初期化できません。1 秒後に再試行します")
                Thread.sleep(forTimeInterval: 1)
                if let r = expired(now: Date()) { return r }
                continue
            }
            stateLock.lock()
            mapping = (capturer.width, capturer.height, capturer.screenWidth, capturer.screenHeight)
            stateLock.unlock()
            hostLog("画面 \(capturer.screenWidth)x\(capturer.screenHeight) → 送信 \(capturer.width)x\(capturer.height)")

            do {
                try channel.send(.hello, Hello(width: capturer.width, height: capturer.height).encode())
            } catch {
                return "disconnected"
            }
            let encoder = FrameEncoder(width: capturer.width, height: capturer.height)
            var lastStats = Date()
            var statsBase = FrameStats()

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
                encoder.format = frameFormat

                // 画面が変わらなければ、何も送らない (止まったあとの高画質化だけは送る)
                var minInterval = interval
                if let image = capturer.capture(),
                   let payload = encoder.encode(image, srcStride: capturer.bytesPerRow) {
                    do {
                        try channel.send(encoder.format == .v2 ? .frame2 : .frame, payload)
                    } catch {
                        return "disconnected"
                    }
                    totalSent += payload.count + 5
                    // 上限があれば、送った量に見合う時間を空ける
                    if options.maxKbps > 0 {
                        minInterval = max(minInterval, Double(payload.count + 5) * 8 / (options.maxKbps * 1000))
                    }
                    // ビューアが処理し終えるまで次を送らない (遅い回線で溜まらないように)
                    _ = ackSemaphore.wait(timeout: .now() + 5)
                }
                if options.statsInterval > 0, Date().timeIntervalSince(lastStats) >= options.statsInterval {
                    let s = encoder.stats
                    let bytes = s.bytes - statsBase.bytes
                    if bytes > 0 {
                        let secs = Date().timeIntervalSince(lastStats)
                        hostLog(String(format: "通信量: 直近 %.0f 秒で %@ (平均 %.0f kbps) / 送信 %d 回・タイル 可逆 %d 粗い %d 高画質化 %d",
                                     secs, formatBytes(bytes), Double(bytes) * 8 / secs / 1000,
                                     s.frames - statsBase.frames, s.losslessTiles - statsBase.losslessTiles,
                                     s.lossyTiles - statsBase.lossyTiles, s.refinedTiles - statsBase.refinedTiles))
                    }
                    statsBase = s
                    lastStats = Date()
                }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < minInterval { Thread.sleep(forTimeInterval: minInterval - elapsed) }
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
        case .frameAck, .requestKeyframe, .capabilities:
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
        case let .capabilities(flags):
            stateLock.lock()
            viewerSupportsFrame2 = flags & ViewerCapability.frame2 != 0
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

func formatBytes(_ n: Int) -> String {
    if n >= 1 << 20 { return String(format: "%.1f MB", Double(n) / Double(1 << 20)) }
    if n >= 1 << 10 { return String(format: "%.0f KB", Double(n) / Double(1 << 10)) }
    return "\(n) B"
}
