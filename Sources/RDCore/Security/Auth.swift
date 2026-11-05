import Foundation

// 接続の流れ:
//   1. TCP 接続
//   2. Noise XX ハンドシェイク (相互に長期鍵を証明、以降はすべて暗号化)
//   3. ビューア: ホスト鍵を検証 (ペアリングコードの指紋 or 信頼済みホスト一覧)。不一致なら即切断
//   4. ビューア → ホスト: authRequest (端末名 + 初回のみペアリング証明)
//   5. ホスト: 端末鍵が許可一覧にあるか、ペアリング証明が正しいかを確認 (+ 任意で画面上の承認)
//   6. ホスト → ビューア: authResult。成功時のみ画面配信・入力受付を開始

public enum AuthStatus: UInt8 {
    case ok = 0
    case unknownDevice = 1
    case pairingFailed = 2
    case rejectedByUser = 3
    case rateLimited = 4
    case badRequest = 5
}

public struct AuthRequest: Equatable {
    public static let maxNameBytes = 128
    public var deviceName: String
    public var pairingProof: [UInt8]? // HMAC-SHA256 (32 バイト)

    public init(deviceName: String, pairingProof: [UInt8]?) {
        self.deviceName = deviceName
        self.pairingProof = pairingProof
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        let name = Array(Array(deviceName.utf8).prefix(Self.maxNameBytes))
        w.u16(UInt16(name.count))
        w.bytes += name
        let proof = pairingProof ?? []
        w.u8(UInt8(proof.count))
        w.bytes += proof
        return w.bytes
    }

    public static func decode(_ p: [UInt8]) throws -> AuthRequest {
        var r = ByteReader(p)
        let n = Int(try r.u16())
        guard n <= maxNameBytes else { throw ProtocolError.invalid("端末名が長すぎます") }
        let start = r.offset
        try r.skip(n)
        let name = String(decoding: p[start ..< start + n], as: UTF8.self)
        let pl = Int(try r.u8())
        guard pl == 0 || pl == 32 else { throw ProtocolError.invalid("証明の長さが不正") }
        let ps = r.offset
        try r.skip(pl)
        guard r.remaining == 0 else { throw ProtocolError.invalid("余分なデータ") }
        return AuthRequest(deviceName: name, pairingProof: pl == 0 ? nil : Array(p[ps ..< ps + pl]))
    }
}

public struct AuthResult: Equatable {
    public var status: AuthStatus
    public var message: String
    /// 成功時: このホストの中継サーバー上の部屋 ID (登録済み端末にだけ、暗号化された通路で渡す)
    public var relayRoom: String?

    public init(status: AuthStatus, message: String, relayRoom: String? = nil) {
        self.status = status
        self.message = message
        self.relayRoom = relayRoom
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.u8(status.rawValue)
        let m = Array(Array(message.utf8).prefix(512))
        w.u16(UInt16(m.count))
        w.bytes += m
        let room = Array((relayRoom ?? "").utf8.prefix(64))
        w.u8(UInt8(room.count))
        w.bytes += room
        return w.bytes
    }

    public static func decode(_ p: [UInt8]) throws -> AuthResult {
        var r = ByteReader(p)
        guard let st = AuthStatus(rawValue: try r.u8()) else { throw ProtocolError.invalid("不明な認証結果") }
        let n = Int(try r.u16())
        let start = r.offset
        try r.skip(n)
        var room: String?
        if r.remaining > 0 {
            let rn = Int(try r.u8())
            let rs = r.offset
            try r.skip(rn)
            let text = String(decoding: p[rs ..< rs + rn], as: UTF8.self)
            if RelayRoom.isValid(text) { room = text }
        }
        return AuthResult(status: st, message: String(decoding: p[start ..< start + n], as: UTF8.self), relayRoom: room)
    }
}

public enum AuthError: Error, CustomStringConvertible {
    case hostKeyMismatch(actual: String)
    case unknownHost(fingerprint: String)
    case rejected(AuthStatus, String)
    case busy
    case rateLimited(seconds: Int)
    case noRelayRoom

    public var description: String {
        switch self {
        case .hostKeyMismatch(let fp):
            return "⚠️ ホストの鍵が登録済みの鍵 (またはペアリングコード) と一致しません。なりすましの可能性があるため接続を中止しました。(相手の指紋: \(fp))"
        case .unknownHost(let fp):
            return "未登録のホストです (指紋: \(fp))。ホストで RDHost --pair を実行し、表示されたペアリングコードを入力してください。"
        case .rejected(let st, let msg):
            return "ホストに拒否されました (\(st)): \(msg)"
        case .busy:
            return "ホストが混雑しています"
        case .rateLimited(let s):
            return "失敗が続いたため \(s) 秒間ブロックされています"
        case .noRelayRoom:
            return "このホストの中継情報がまだありません。一度、同じ Wi-Fi で直接接続してください (中継の設定はそのとき自動で受け取ります)"
        }
    }
}

// MARK: - ホスト側

/// 総当たり対策: IP ごとの失敗回数で指数的にブロック時間を延ばす
public final class RateLimiter {
    private var state: [String: (failures: Int, blockedUntil: Date)] = [:]
    private let lock = NSLock()
    public let freeFailures: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(freeFailures: Int = 3, baseDelay: TimeInterval = 30, maxDelay: TimeInterval = 3600) {
        self.freeFailures = freeFailures
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// ブロック中なら残り秒数
    public func blockedFor(_ key: String, now: Date = Date()) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let s = state[key], s.blockedUntil > now else { return nil }
        return s.blockedUntil.timeIntervalSince(now)
    }

    public func recordFailure(_ key: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let f = (state[key]?.failures ?? 0) + 1
        var until = now
        if f >= freeFailures {
            let exp = Double(min(f - freeFailures, 20))
            until = now.addingTimeInterval(min(maxDelay, baseDelay * pow(2, exp)))
        }
        state[key] = (f, until)
        if state.count > 10000 { state = state.filter { $0.value.blockedUntil > now } } // メモリ枯渇対策
    }

    public func recordSuccess(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        state[key] = nil
    }
}

/// 新しい端末を登録できる期間。コードは 1 回使えば無効、失敗が続いても無効。
public final class PairingWindow {
    public let code: PairingCode
    public let expires: Date
    public let maxFailures: Int
    private var failures = 0
    private var used = false
    private let lock = NSLock()

    public init(hostPublicKey: [UInt8], lifetime: TimeInterval = 600, maxFailures: Int = 5) {
        code = PairingCode(hostPublicKey: hostPublicKey)
        expires = Date().addingTimeInterval(lifetime)
        self.maxFailures = maxFailures
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !used && failures < maxFailures && Date() < expires
    }

    public enum Outcome { case accepted, wrong, inactive }

    /// 証明を確かめる (正しくてもまだ使用済みにはしない。画面での許可のあとで markUsed する)
    public func check(proof: [UInt8], handshakeHash: [UInt8]) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        guard !used, failures < maxFailures, Date() < expires else { return .inactive }
        if code.verify(proof: proof, handshakeHash: handshakeHash) { return .accepted }
        failures += 1
        return .wrong
    }

    /// 登録が確定したら使用済みにする。すでに別の接続が使っていれば false
    public func markUsed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used, Date() < expires else { return false }
        used = true
        return true
    }

    /// 画面で拒否された登録 (コードは使用済みにしないが、失敗として数える)
    public func recordDenied() {
        lock.lock(); defer { lock.unlock() }
        failures += 1
    }

    public func consume(proof: [UInt8], handshakeHash: [UInt8]) -> Outcome {
        let r = check(proof: proof, handshakeHash: handshakeHash)
        if r == .accepted && !markUsed() { return .inactive }
        return r
    }
}

/// 接続を受け付けてよいか判断する門番
public final class HostGatekeeper {
    public struct Client {
        public let channel: MessageChannel
        public let name: String
        public let publicKey: [UInt8]
        public let peer: String
        public let isPostQuantum: Bool
    }

    /// 画面上で接続を承認するか (nil なら確認しない)。引数: 端末名, 指紋, 接続元, 新規端末か
    public typealias ConsentHandler = (_ name: String, _ fingerprint: String, _ peer: String, _ isNew: Bool) -> Bool

    public let identity: StaticIdentity
    public let clients: TrustStore
    public let audit: AuditLog
    public let limiter = RateLimiter()
    public var consent: ConsentHandler?
    public var handshakeTimeout: TimeInterval = 10
    /// false (既定) なら、新しい端末の登録は LAN 内からの直接接続でだけ受け付ける。
    /// コードを盗み見られても、外からは端末を追加できない。
    public var allowRemotePairing = false
    /// 新しい端末を登録するときの確認 (必須)。ホストの画面で利用者が許可したときだけ true を返すこと。
    /// nil のときは新しい端末を登録できない。
    public var newDeviceConsent: ConsentHandler?
    /// 登録済み端末に渡す中継の部屋 ID
    public var relayRoom: String?
    /// 耐量子鍵交換 (ML-KEM) に対応していない端末を拒否する
    public var requirePostQuantum = false
    public let maxPendingHandshakes = 4

    private var pairing: PairingWindow?
    private var pending = 0
    private let lock = NSLock()

    public init(identity: StaticIdentity, clients: TrustStore, audit: AuditLog) {
        self.identity = identity
        self.clients = clients
        self.audit = audit
    }

    /// ペアリングを開始してコードを返す
    public func startPairing(lifetime: TimeInterval = 600) -> PairingWindow {
        let w = PairingWindow(hostPublicKey: identity.publicKey, lifetime: lifetime)
        lock.lock(); pairing = w; lock.unlock()
        return w
    }

    public var currentPairing: PairingWindow? {
        lock.lock(); defer { lock.unlock() }
        return pairing
    }

    /// 接続中の端末がまだ許可されているか (失効されたら接続中のセッションも切る)
    public func isStillAuthorized(_ publicKey: [UInt8]) -> Bool {
        clients.reload()
        return clients.find(publicKey: publicKey) != nil
    }

    /// 認証に成功したら Client を返す。失敗時は接続を閉じて例外。
    public func authenticate(_ tcp: Transport) throws -> Client {
        let peer = tcp.peerDescription
        let ip = tcp.peerIP

        if let wait = limiter.blockedFor(ip) {
            audit.record("BLOCKED ip=\(ip) remaining=\(Int(wait))s")
            tcp.close()
            throw AuthError.rateLimited(seconds: Int(wait))
        }
        lock.lock()
        if pending >= maxPendingHandshakes {
            lock.unlock()
            tcp.close()
            throw AuthError.busy
        }
        pending += 1
        lock.unlock()
        defer { lock.lock(); pending -= 1; lock.unlock() }

        tcp.setReceiveTimeout(handshakeTimeout)
        let secure: SecureStream
        do {
            secure = try SecureStream.accept(tcp, identity: identity, requirePostQuantum: requirePostQuantum)
        } catch {
            limiter.recordFailure(ip)
            audit.record("HANDSHAKE_FAIL peer=\(peer) error=\(error)")
            tcp.close()
            throw error
        }
        // 認証前は小さなメッセージしか受け付けない
        let pre = MessageChannel(secure, maxPayload: 1024)
        let fp = Fingerprint.display(secure.remoteStaticKey)

        func reject(_ st: AuthStatus, _ msg: String, countFailure: Bool = true) -> AuthError {
            if countFailure { limiter.recordFailure(ip) }
            audit.record("AUTH_REJECT peer=\(peer) device=\(fp) status=\(st) reason=\(msg)")
            try? pre.send(.authResult, AuthResult(status: st, message: msg).encode())
            secure.close()
            return AuthError.rejected(st, msg)
        }

        let req: AuthRequest
        do {
            let (type, payload) = try pre.receive()
            guard type == MessageType.authRequest.rawValue else { throw reject(.badRequest, "認証要求がありません") }
            req = try AuthRequest.decode(payload)
        } catch let e as AuthError {
            throw e
        } catch {
            throw reject(.badRequest, "認証要求が不正です")
        }
        let name = sanitize(req.deviceName, maxLength: 64)

        var isNew = false
        var pairingWindow: PairingWindow?
        clients.reload()
        if clients.isTampered {
            audit.record("TRUST_STORE_TAMPERED action=reject_all")
            throw reject(.badRequest, "ホストの設定に問題があります", countFailure: false)
        }
        if clients.find(publicKey: secure.remoteStaticKey) != nil {
            // 登録済みの端末
        } else if let proof = req.pairingProof {
            guard tcp.isLocalNetwork || allowRemotePairing else {
                throw reject(.pairingFailed, "新しい端末の登録は、同じ LAN (Wi-Fi) から直接接続したときだけ受け付けます")
            }
            guard let window = currentPairing else {
                throw reject(.pairingFailed, "ホストはペアリング受付中ではありません (RDHost --pair)")
            }
            switch window.check(proof: proof, handshakeHash: secure.handshakeHash) {
            case .accepted:
                isNew = true
                pairingWindow = window
            case .wrong:
                let left = window.isActive ? "" : " — 失敗回数が上限に達したためコードを無効化しました"
                if !window.isActive { audit.record("PAIRING_CODE_REVOKED reason=too_many_failures") }
                throw reject(.pairingFailed, "ペアリングコードが違います\(left)")
            case .inactive:
                throw reject(.pairingFailed, "ペアリングコードは期限切れか使用済みです")
            }
        } else {
            throw reject(.unknownDevice, "未登録の端末です。ホストで RDHost --pair を実行してペアリングしてください")
        }

        // 新しい端末の登録は、ホストの画面で必ず許可を得る (無効にできない)。
        // 登録済み端末の接続ごとの確認は任意 (--confirm)。
        if let ask = consent ?? (isNew ? newDeviceConsent : nil) {
            tcp.setReceiveTimeout(0)
            guard ask(name, fp, peer, isNew) else {
                // 拒否してもコードは使用済みにしない (本人がやり直せるように)。ただし失敗として数える
                pairingWindow?.recordDenied()
                throw reject(.rejectedByUser, "ホストの利用者が接続を拒否しました", countFailure: false)
            }
        } else if isNew {
            throw reject(.pairingFailed, "ホストの画面で登録を許可できないため、新しい端末を登録できません", countFailure: false)
        }

        if isNew {
            guard pairingWindow?.markUsed() == true else {
                throw reject(.pairingFailed, "ペアリングコードは期限切れか使用済みです")
            }
            do {
                try clients.add(publicKey: secure.remoteStaticKey, name: name)
            } catch {
                throw reject(.badRequest, "端末を登録できませんでした", countFailure: false)
            }
            audit.record("DEVICE_PAIRED name=\(name) device=\(fp) peer=\(peer)")
        } else {
            clients.touch(publicKey: secure.remoteStaticKey)
        }

        limiter.recordSuccess(ip)
        try pre.send(.authResult, AuthResult(status: .ok, message: "ok", relayRoom: relayRoom).encode())
        tcp.setReceiveTimeout(0)
        audit.record("SESSION_START name=\(name) device=\(fp) peer=\(peer) pq=\(secure.isPostQuantum)")
        return Client(channel: MessageChannel(secure), name: name, publicKey: secure.remoteStaticKey, peer: peer,
                      isPostQuantum: secure.isPostQuantum)
    }
}

// MARK: - ビューア側

public enum ViewerConnector {
    public struct Session {
        public let channel: MessageChannel
        public let hostPublicKey: [UInt8]
        public let hostFingerprint: String
        public let newlyPaired: Bool
        public let isPostQuantum: Bool
    }

    /// 接続先
    public enum Endpoint {
        /// LAN 内などで直接 TCP 接続
        case direct(host: String, port: UInt16)
        /// 中継サーバー経由
        case relay(URL)
    }

    /// 接続・ホスト検証・認証まで行う。
    /// - expectedHostKey: 保存済みのホストに接続するときはその公開鍵。完全一致しなければ切断する。
    /// - pairingCode: 初回のみ。ホスト鍵の指紋がコードと一致しなければ切断する。
    public static func connect(to endpoint: Endpoint, identity: StaticIdentity, knownHosts: TrustStore,
                               expectedHostKey: [UInt8]? = nil, pairingCode: PairingCode?,
                               deviceName: String) throws -> Session {
        let transport: Transport
        let label: String
        switch endpoint {
        case let .direct(host, port):
            transport = try TCPConnection.open(host: host, port: port)
            label = "\(host):\(port)"
        case let .relay(url):
            // 部屋 ID は、LAN で接続したときにホストから暗号化して受け取ったもの。
            // 中継経由で初めて接続することはできない (端末の登録は LAN 限定)。
            guard let key = expectedHostKey, let room = knownHosts.find(publicKey: key)?.relayRoom else {
                throw AuthError.noRelayRoom
            }
            transport = try RelayTransport.connect(relay: url, room: room)
            label = "relay"
        }
        return try connect(transport: transport, label: label, identity: identity, knownHosts: knownHosts,
                           expectedHostKey: expectedHostKey, pairingCode: pairingCode, deviceName: deviceName)
    }

    /// 互換用 (直接接続)
    public static func connect(host: String, port: UInt16, identity: StaticIdentity, knownHosts: TrustStore,
                               pairingCode: PairingCode?, deviceName: String) throws -> Session {
        try connect(to: .direct(host: host, port: port), identity: identity, knownHosts: knownHosts,
                    pairingCode: pairingCode, deviceName: deviceName)
    }

    static func connect(transport tcp: Transport, label: String, identity: StaticIdentity, knownHosts: TrustStore,
                        expectedHostKey: [UInt8]?, pairingCode: PairingCode?, deviceName: String) throws -> Session {
        tcp.setReceiveTimeout(20)
        let secure: SecureStream
        do {
            secure = try SecureStream.connect(tcp, identity: identity)
        } catch {
            tcp.close()
            throw error
        }
        let hostKey = secure.remoteStaticKey
        let fp = Fingerprint.display(hostKey)

        // ホストの本人確認。ここを通るまでは何も送らない。
        var proof: [UInt8]?
        if let expected = expectedHostKey {
            guard expected == hostKey else {
                secure.close()
                throw AuthError.hostKeyMismatch(actual: fp)
            }
        } else if knownHosts.find(publicKey: hostKey) != nil {
            // 信頼済みのホスト
        } else if let code = pairingCode {
            guard code.matches(hostPublicKey: hostKey) else {
                secure.close()
                throw AuthError.hostKeyMismatch(actual: fp)
            }
            proof = code.proof(handshakeHash: secure.handshakeHash)
        } else {
            secure.close()
            throw AuthError.unknownHost(fingerprint: fp)
        }

        let ch = MessageChannel(secure, maxPayload: 4096)
        try ch.send(.authRequest, AuthRequest(deviceName: deviceName, pairingProof: proof).encode())
        tcp.setReceiveTimeout(90) // ホスト側で承認ダイアログが出る場合がある
        let (type, payload) = try ch.receive()
        guard type == MessageType.authResult.rawValue else {
            secure.close()
            throw ProtocolError.invalid("認証結果がありません")
        }
        let result = try AuthResult.decode(payload)
        guard result.status == .ok else {
            secure.close()
            throw AuthError.rejected(result.status, sanitize(result.message))
        }
        tcp.setReceiveTimeout(0)
        if proof != nil {
            try knownHosts.add(publicKey: hostKey, name: sanitize(label), relayRoom: result.relayRoom)
        } else {
            knownHosts.touch(publicKey: hostKey)
            if let room = result.relayRoom { try? knownHosts.setRelayRoom(publicKey: hostKey, room: room) }
        }
        return Session(channel: MessageChannel(secure), hostPublicKey: hostKey, hostFingerprint: fp,
                       newlyPaired: proof != nil, isPostQuantum: secure.isPostQuantum)
    }
}
