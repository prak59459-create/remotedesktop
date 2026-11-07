import Foundation
import RDCore

/// ホストの本体。コマンドライン版 (RDHost) と GUI 版 (RemoteDesktopHost) の両方から使う。
/// 鍵と許可端末の一覧を読み込み、直接接続 (TCP) と中継サーバーで待ち受け、認証できた端末にセッションを渡す。
public final class HostService {
    public struct Device: Equatable {
        public let name: String
        public let fingerprint: String
        public let added: Date
        public let lastSeen: Date?
    }

    public enum RelayState: Equatable {
        case off
        case connecting
        case up(transport: String)
        case down(reason: String)
    }

    public private(set) var options: HostOptions
    public let fingerprint: String
    /// 許可端末の一覧が改ざんされている (すべての接続を拒否する)
    public var isTampered: Bool { clients.isTampered }

    /// 状態が変わったとき (別スレッドから呼ばれる)
    public var onChange: (() -> Void)?
    /// 監査ログに 1 行書いたとき (別スレッドから呼ばれる。GUI のログ欄に出す)
    public var onAudit: ((String) -> Void)?

    private let identity: StaticIdentity
    private let clients: TrustStore
    private let roomToken: [UInt8]
    private let audit: AuditLog
    private let gate: HostGatekeeper
    private let consentGate = ConsentGate()
    private let lock = NSLock()
    private var listener: TCPListener?
    private var relayListener: RelayHostListener?
    private var _running = false
    private var _relayState = RelayState.off
    private var _directEndpoint: String?
    private var _bonjourName: String?
    private var _lastTraffic: String?

    public init(options: HostOptions) throws {
        self.options = options
        identity = try SecretStore.loadOrCreateIdentity(name: "host_identity")
        // 許可端末の一覧は、ホストの秘密鍵 (TPM + DPAPI で保護) から導出した鍵で署名する。
        // ファイルだけ書き換えても、署名の鍵だけ消しても端末を追加できない。
        clients = try TrustStore(fileName: "authorized_devices.json", integrityKey: TrustStore.integrityKey(for: identity))
        roomToken = try SecretStore.loadOrCreateSecret(name: "relay_room_token").bytes
        fingerprint = identity.fingerprint
        audit = AuditLog()
        gate = HostGatekeeper(identity: identity, clients: clients, audit: audit)
        audit.mirror = { [weak self] line, important in
            writeEventLog(line, warning: important)
            self?.onAudit?(line)
        }
        if clients.isTampered { audit.record("TRUST_STORE_TAMPERED") }
        ActiveSessions.shared.onChange = { [weak self] in self?.onChange?() }
        // 通信量の表示は、最新のものを状態として覚えておく (GUI に出す)
        let previous = HostLog.sink
        HostLog.sink = { [weak self] line in
            if line.hasPrefix("通信量:") {
                self?.lock.lock(); self?._lastTraffic = line; self?.lock.unlock()
                self?.onChange?()
            }
            previous(line)
        }
    }

    // MARK: 状態

    public var isRunning: Bool { locked { _running } }
    public var relayState: RelayState { locked { _relayState } }
    /// 直接接続の待ち受け先 (例: 192.168.0.10:5999)
    public var directEndpoint: String? { locked { _directEndpoint } }
    /// Bonjour で知らせている PC の名前
    public var bonjourName: String? { locked { _bonjourName } }
    /// 最新の「通信量:」の行
    public var lastTraffic: String? { locked { _lastTraffic } }
    /// 接続中の端末
    public var sessions: [String] { ActiveSessions.shared.current }

    /// 受付中のペアリングコード (無ければ nil)
    public var pairing: (code: String, expires: Date)? {
        guard let w = gate.currentPairing, w.isActive else { return nil }
        return (w.code.string, w.expires)
    }

    public var devices: [Device] {
        clients.all.map { e in
            Device(name: e.name, fingerprint: Fingerprint.fromHex(e.publicKey).map(Fingerprint.display) ?? "?",
                   added: e.added, lastSeen: e.lastSeen)
        }
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return f()
    }

    // MARK: 端末の管理

    /// 指紋の先頭 (4 文字以上) で端末の登録を取り消す。接続中なら 2 秒以内に切断される
    @discardableResult
    public func revoke(_ query: String) throws -> Int {
        let n = try clients.remove(matching: query)
        if n > 0 { audit.record("DEVICE_REVOKED query=\(query) count=\(n)") }
        onChange?()
        return n
    }

    public func resetDevices() throws {
        try clients.reset()
        audit.record("DEVICES_RESET")
        onChange?()
    }

    /// 新しい端末を登録するためのコードを出す (10 分間・1 回限り)
    @discardableResult
    public func startPairing() -> (code: String, expires: Date) {
        let w = gate.startPairing()
        audit.record("PAIRING_STARTED")
        onChange?()
        return (w.code.string, w.expires)
    }

    /// 管理者権限で動いているなど、起動してはいけない理由
    public static func environmentProblem(allowAdmin: Bool) -> String? {
        if isRunningElevated() && !allowAdmin {
            return "管理者権限で起動されています。乗っ取られたときの被害を小さくするため、通常のユーザーで起動してください。"
        }
        return nil
    }

    public static func setupPlatform() { platformSetup() }

    // MARK: 待ち受け

    /// 設定を変える (待ち受け中なら、止めてから新しい設定で始め直す)
    public func update(options newOptions: HostOptions) throws {
        let wasRunning = isRunning
        if wasRunning { stop() }
        options = newOptions
        if wasRunning { try start() }
    }

    /// 待ち受けを始める (すぐ戻る。待ち受けは別スレッド)
    public func start() throws {
        lock.lock()
        if _running {
            lock.unlock()
            return
        }
        lock.unlock()
        guard options.direct || options.relay != nil else {
            throw HostError.nothingToListen
        }
        ActiveSessions.shared.onDisconnect = options.onDisconnect
        gate.allowRemotePairing = options.allowRemotePairing
        gate.requirePostQuantum = options.requirePostQuantum
        gate.relayRoom = options.relay != nil ? RelayRoom.id(token: roomToken) : nil
        let ask: HostGatekeeper.ConsentHandler = { [consentGate] in consentGate.ask($0, $1, $2, $3) }
        gate.newDeviceConsent = ask // 新しい端末の登録は必ず画面で確認
        gate.consent = options.confirm ? ask : nil

        var newListener: TCPListener?
        var endpoint: String?
        var bonjour: String?
        if options.direct {
            // 止めた直後はポートがまだ空いていないことがあるので、少しだけ待って試し直す
            var lastError: Error?
            for _ in 0 ..< 10 {
                do {
                    newListener = try TCPListener(port: options.port, bindAddress: options.bindAddress)
                    break
                } catch {
                    lastError = error
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
            guard let l = newListener else { throw lastError ?? HostError.nothingToListen }
            let lanIP = options.bindAddress ?? Net.primaryLocalIPv4()
            endpoint = "\(lanIP ?? "0.0.0.0"):\(l.boundPort)"
            hostLog("直接接続: \(options.bindAddress ?? "0.0.0.0"):\(l.boundPort) で待ち受け中")
            if options.bonjour {
                let pcName = computerName()
                if let err = advertiseBonjour(name: pcName, port: l.boundPort, ip: lanIP) {
                    hostLog("※ Bonjour での公開に失敗しました (\(err))。iPad では IP アドレスで接続してください")
                } else {
                    bonjour = pcName
                    hostLog("同じ Wi-Fi の iPad の接続画面に「\(pcName)」が表示されます")
                }
            }
            if let ip = lanIP { hostLog("IP アドレスで接続する場合: \(ip)  ポート \(l.boundPort)") }
        }

        var relay: RelayHostListener?
        if let url = options.relay {
            if url.scheme == "http" || url.scheme == "ws" {
                hostLog("⚠️ 中継サーバーへの経路が TLS ではありません (中身は端末間で暗号化済みですが、https:// を推奨します)")
            }
            let audit = self.audit
            relay = RelayHostListener(relay: url, roomToken: roomToken) { [weak self] line in
                audit.record(line)
                self?.noteRelay(line)
            }
            hostLog("中継サーバー: \(url.absoluteString) で待ち受け中 (ポート開放は不要・通り道: \(RelayTransportMode.default.rawValue))")
        }

        lock.lock()
        listener = newListener
        relayListener = relay
        _directEndpoint = endpoint
        _bonjourName = bonjour
        _relayState = relay != nil ? .connecting : .off
        _running = true
        lock.unlock()

        if let l = newListener {
            Thread { [weak self] in self?.acceptLoop(l) }.start()
        }
        if let r = relay {
            Thread { [weak self] in r.run(onIncoming: { self?.serve($0) }) }.start()
        }
        audit.record("HOST_START direct=\(options.direct) relay=\(options.relay?.host ?? "-") confirm=\(options.confirm) remote_pairing=\(options.allowRemotePairing) require_pq=\(options.requirePostQuantum)")
        onChange?()
    }

    /// 待ち受けをやめる (接続中のセッションはそのまま)
    public func stop() {
        lock.lock()
        let l = listener, r = relayListener
        listener = nil
        relayListener = nil
        _running = false
        _relayState = .off
        _directEndpoint = nil
        _bonjourName = nil
        lock.unlock()
        l?.close()
        r?.stop()
        audit.record("HOST_STOP")
        hostLog("待ち受けを止めました")
        onChange?()
    }

    private func acceptLoop(_ l: TCPListener) {
        while !l.isClosed {
            do {
                serve(try l.accept())
            } catch {
                if l.isClosed { break }
                hostLog("accept エラー: \(error)")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func serve(_ transport: Transport) {
        let gate = self.gate, options = self.options, audit = self.audit
        Thread {
            do {
                let client = try gate.authenticate(transport)
                HostSession(client: client, gate: gate, options: options, audit: audit).run()
            } catch {
                // 理由は監査ログに記録済み
            }
        }.start()
    }

    private func noteRelay(_ line: String) {
        lock.lock()
        if line.hasPrefix("RELAY_UP") {
            let transport = line.components(separatedBy: "transport=").last ?? ""
            _relayState = .up(transport: transport)
        } else if line.hasPrefix("RELAY_DOWN") {
            _relayState = .down(reason: line.replacingOccurrences(of: "RELAY_DOWN ", with: ""))
        }
        lock.unlock()
        onChange?()
    }

    // MARK: 監査ログ

    public static func verifyAuditLog() -> String {
        switch AuditLog.verify() {
        case .ok(let n): return "監査ログは改ざんされていません (\(n) 行)"
        case .broken(let line): return "⚠️ 監査ログの \(line) 行目以降が改ざん・削除されています"
        case .missing: return "監査ログがありません"
        }
    }
}

public enum HostError: Error, CustomStringConvertible {
    case nothingToListen

    public var description: String {
        switch self {
        case .nothingToListen: return "直接接続も中継サーバーも使わない設定になっています"
        }
    }
}

/// 確認ダイアログは同時に 1 つだけ。開いている間に来た要求は待たせずに拒否する
/// (答えのないダイアログの後ろに接続が溜まって、ホストが受け付けられなくなるのを防ぐ)
final class ConsentGate {
    private let lock = NSLock()
    private var open = false

    func ask(_ name: String, _ fp: String, _ peer: String, _ isNew: Bool) -> Bool {
        lock.lock()
        if open {
            lock.unlock()
            return false
        }
        open = true
        lock.unlock()
        defer { lock.lock(); open = false; lock.unlock() }
        return askConsent(name: name, fingerprint: fp, peer: peer, isNew: isNew)
    }
}

// MARK: - GUI 版の設定 (ファイルに保存)

public struct HostSettings: Codable, Equatable {
    public var relayURL = ""
    public var relayTransport = RelayTransportMode.auto.rawValue
    public var direct = true
    public var port = Int(defaultPort)
    public var bonjour = true
    public var confirm = false
    public var onDisconnect = DisconnectAction.blank.rawValue
    public var idleMinutes = 15.0
    public var fps = 30.0
    public var scale = 1
    public var maxKbps = 0.0
    public var requirePostQuantum = false
    /// 起動したらすぐ待ち受けを始める
    public var autoStart = true
    /// 閉じるボタンでタスクトレイにしまう
    public var closeToTray = true

    public init() {}

    static let fileName = "host_settings.json"

    public static func load() -> HostSettings {
        guard let url = try? DataDirectory.url().appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(HostSettings.self, from: data) else { return HostSettings() }
        return s
    }

    public func save() throws {
        let url = try DataDirectory.url().appendingPathComponent(Self.fileName)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// 入力の不備 (無ければ nil)
    public var problem: String? {
        if !relayURL.isEmpty {
            guard let u = URL(string: relayURL), ["https", "wss", "http", "ws"].contains(u.scheme ?? ""), u.host != nil else {
                return "中継サーバーの URL は https:// で始めてください"
            }
        }
        if !(1 ... 65535).contains(port) { return "ポート番号は 1〜65535 にしてください" }
        if !direct && relayURL.isEmpty { return "直接接続を使わないときは、中継サーバーの URL を入れてください" }
        return nil
    }

    public var options: HostOptions {
        var o = HostOptions()
        o.relay = relayURL.isEmpty ? nil : URL(string: relayURL)
        o.direct = direct
        o.port = UInt16(clamping: port)
        o.bonjour = bonjour
        o.confirm = confirm
        o.onDisconnect = DisconnectAction(rawValue: onDisconnect) ?? .blank
        o.idleTimeout = max(1, idleMinutes) * 60
        o.fps = min(60, max(1, fps))
        o.scale = min(8, max(1, scale))
        o.maxKbps = max(0, maxKbps)
        o.requirePostQuantum = requirePostQuantum
        return o
    }
}
