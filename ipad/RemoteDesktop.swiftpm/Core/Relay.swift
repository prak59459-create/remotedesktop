// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/Relay.swift からコピー。直接編集しないでください。
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// 中継サーバー経由の接続。
// ホストもビューアも中継サーバーへ外向きに接続するだけなので、自宅のルーターでポートを開ける必要がない。
// 中継サーバーは暗号文を受け渡すだけで、鍵を持たないので中身を読めない。改ざんすれば Noise が検出して切断する。

public enum RelayRoom {
    /// 部屋 ID = SHA-256(ラベル || 部屋トークン) の先頭 128bit を Base32 (26 文字)。
    /// トークンはホストだけが持つ 256bit の秘密で、中継サーバーは「ID がトークンのハッシュと一致するか」を確かめてから
    /// 待ち受けを登録させる。ID を知っていてもトークンは分からないので、部屋の先取り・乗っ取りはできない。
    /// ID は登録済みの端末にだけ、暗号化された通路で渡す。
    public static let label = "RemoteDesktop relay room v2"

    public static func id(token: [UInt8]) -> String {
        let digest = SHA256.hash(data: Array(label.utf8) + token)
        return Base32.encode(Array(Array(digest).prefix(16)))
    }

    public static func isValid(_ room: String) -> Bool {
        room.count == 26 && room.utf8.allSatisfy { Base32.alphabet.contains($0) }
    }

    static func url(_ base: URL, path: String, query: [String: String]) throws -> URL {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw WebSocketError.badURL(base.absoluteString)
        }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = "wss"
        case "http": c.scheme = "ws"
        case "wss", "ws": break
        default: throw WebSocketError.badURL(base.absoluteString)
        }
        let basePath = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        c.path = basePath + path
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = c.url else { throw WebSocketError.badURL(base.absoluteString) }
        return u
    }
}

/// 中継サーバーへの通り道の選び方
public enum RelayTransportMode: String, CaseIterable {
    /// WebSocket を試し、つながらなければ HTTP (一度 HTTP に切り替わったら、以降は HTTP を先に試す)
    case auto
    case webSocket = "websocket"
    /// 普通の HTTP リクエストだけ (WebSocket を通さないプロキシや社内ネットワーク向け)
    case http

    /// 既定の選び方 (アプリやコマンドラインのオプションで変える)
    public static var `default`: RelayTransportMode {
        get { lock.lock(); defer { lock.unlock() }; return _default }
        set { lock.lock(); _default = newValue; lock.unlock() }
    }

    private static let lock = NSLock()
    private static var _default: RelayTransportMode = .auto
    private static var _preferHTTP = false

    /// auto のとき、前回 WebSocket がつながらず HTTP でつながったか
    static var preferHTTP: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _preferHTTP }
        set { lock.lock(); _preferHTTP = newValue; lock.unlock() }
    }
}

/// 受信スレッドが受け取ったバイト列を貯めて、receive(exactly:) で渡す
final class ByteInbox {
    struct Timeout: Error {}

    private let cond = NSCondition()
    private var buffer: [UInt8] = []
    private var offset = 0
    private var finished = false
    private var timeout: Double = 0
    static let maxBuffered = 32 * 1024 * 1024

    /// 貯める。受信側が読まないまま溜まりすぎたら false (呼び出し側が切断する)
    func append(_ b: [UInt8]) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        // 読み終えた部分を捨てる (受信側が少しでも遅れていると、ここで詰めないと際限なく増える)
        if offset > 0 && (offset == buffer.count || offset >= 1 << 20) {
            buffer.removeFirst(offset)
            offset = 0
        }
        buffer += b
        cond.broadcast()
        return buffer.count - offset <= Self.maxBuffered
    }

    func finish() {
        cond.lock(); finished = true; cond.broadcast(); cond.unlock()
    }

    func setTimeout(_ seconds: Double) {
        cond.lock(); timeout = seconds; cond.unlock()
    }

    func receive(exactly n: Int) throws -> [UInt8] {
        cond.lock()
        defer { cond.unlock() }
        let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : nil
        while buffer.count - offset < n {
            if finished { throw NetError.closed }
            if let d = deadline {
                if !cond.wait(until: d) && buffer.count - offset < n { throw Timeout() }
            } else {
                cond.wait()
            }
        }
        let out = Array(buffer[offset ..< offset + n])
        offset += n
        return out
    }
}

/// WebSocket を Transport (バイトストリーム) として使う。受信は専用スレッドで読み、タイムアウトを扱えるようにする。
public final class RelayTransport: Transport {
    public let peerDescription: String
    public let peerIP: String
    public var isLocalNetwork: Bool { false }

    private let ws: WebSocketConnection
    private let inbox = ByteInbox()

    init(ws: WebSocketConnection, peer: String, peerIP: String) {
        self.ws = ws
        peerDescription = peer
        self.peerIP = peerIP
        Thread { [weak self] in self?.readLoop() }.start()
    }

    private func readLoop() {
        while true {
            let msg: WebSocketMessage
            do {
                msg = try ws.receive()
            } catch {
                break
            }
            guard case .binary(let b) = msg else { break } // データ経路はバイナリだけ
            if !inbox.append(b) { break }
        }
        inbox.finish()
        ws.close()
    }

    public func setReceiveTimeout(_ seconds: Double) {
        inbox.setTimeout(seconds)
    }

    public func sendAll(_ bytes: [UInt8]) throws {
        try ws.send(.binary(bytes))
    }

    public func receive(exactly n: Int) throws -> [UInt8] {
        do {
            return try inbox.receive(exactly: n)
        } catch is ByteInbox.Timeout {
            ws.close()
            throw NetError.io("受信タイムアウト")
        }
    }

    public func close() { ws.close() }

    // MARK: ビューア側

    /// 中継サーバー経由でホストの部屋に接続する。mode が auto なら WebSocket、だめなら HTTP
    public static func connect(relay: URL, room: String,
                               mode: RelayTransportMode = .default) throws -> Transport {
        switch mode {
        case .webSocket: return try connectWebSocket(relay: relay, room: room)
        case .http: return try HTTPRelayTransport.connect(relay: relay, room: room)
        case .auto:
            let order: [RelayTransportMode] = RelayTransportMode.preferHTTP ? [.http, .webSocket] : [.webSocket, .http]
            var firstError: Error?
            for m in order {
                do {
                    let t = try connect(relay: relay, room: room, mode: m)
                    RelayTransportMode.preferHTTP = m == .http
                    return t
                } catch let e as RelayError {
                    // HTTP で中継サーバーには届いた (PC がオフラインなど)。通り道を変えても同じなので、この理由を返す
                    throw e
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            throw firstError ?? NetError.closed
        }
    }

    static func connectWebSocket(relay: URL, room: String) throws -> RelayTransport {
        let url = try RelayRoom.url(relay, path: "/connect", query: ["room": room])
        let ws = try WebSocketClient.connect(url)
        return RelayTransport(ws: ws, peer: "relay:\(relay.host ?? "?")", peerIP: "relay")
    }
}

/// ホスト側: 中継サーバーに待ち受けを登録し、ビューアが来たら Transport を渡す。切れたら自動で再接続する。
/// 通り道は WebSocket か HTTP (ロングポーリング)。auto なら WebSocket がつながらないときに HTTP を使う。
public final class RelayHostListener {
    public let relay: URL
    public let room: String
    public let mode: RelayTransportMode
    private let log: (String) -> Void
    private var stopped = false
    private let lock = NSLock()
    private var control: WebSocketConnection?
    private var backoff = 2.0

    private let token: [UInt8]

    /// 最初の接続そのものに失敗した (通り道の問題かもしれないので、auto ならもう一方を試す)
    private struct ConnectFailed: Error {
        let underlying: Error
    }

    public init(relay: URL, roomToken: [UInt8], mode: RelayTransportMode = .default, log: @escaping (String) -> Void) {
        self.relay = relay
        token = roomToken
        room = RelayRoom.id(token: roomToken)
        self.mode = mode
        self.log = log
    }

    public func stop() {
        lock.lock()
        stopped = true
        let c = control
        lock.unlock()
        c?.close()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// ブロッキングで動き続ける。onIncoming は新しいスレッドで呼ばれる。
    public func run(onIncoming: @escaping (Transport) -> Void) {
        var useHTTP = mode == .http || (mode == .auto && RelayTransportMode.preferHTTP)
        while !isStopped {
            do {
                do {
                    try useHTTP ? serveHTTP(onIncoming) : serveWebSocket(onIncoming)
                } catch let e as ConnectFailed where mode == .auto {
                    // つながらなかった。もう一方の通り道を試す
                    log("RELAY_FALLBACK from=\(useHTTP ? "http" : "websocket") error=\(e.underlying)")
                    useHTTP.toggle()
                    RelayTransportMode.preferHTTP = useHTTP
                    try useHTTP ? serveHTTP(onIncoming) : serveWebSocket(onIncoming)
                }
            } catch {
                if isStopped { break }
                let e = (error as? ConnectFailed)?.underlying ?? error
                log("RELAY_DOWN error=\(e) retry_in=\(Int(backoff))s")
            }
            lock.lock(); control = nil; lock.unlock()
            if isStopped { break }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 60)
        }
    }

    private func up(_ transport: String) {
        log("RELAY_UP relay=\(relay.host ?? "?") transport=\(transport)")
        backoff = 2
    }

    // MARK: WebSocket

    private func serveWebSocket(_ onIncoming: @escaping (Transport) -> Void) throws {
        let ws: WebSocketConnection
        do {
            ws = try WebSocketClient.connect(try RelayRoom.url(relay, path: "/host", query: ["room": room]))
        } catch {
            throw ConnectFailed(underlying: error)
        }
        // トークンは URL に入れない (中継サーバーやプロキシのアクセスログに残さないため)
        try ws.send(.text("{\"t\":\"auth\",\"token\":\"\(Fingerprint.hex(token))\"}"))
        lock.lock(); control = ws; lock.unlock()
        up("websocket")
        try serve(ws, onIncoming: onIncoming)
    }

    private func serve(_ ws: WebSocketConnection, onIncoming: @escaping (Transport) -> Void) throws {
        // 生存確認 (無料サーバーのスリープや NAT のタイムアウト対策)
        final class Liveness {
            let cond = NSCondition()
            var lastPong = Date()
            var done = false
        }
        let live = Liveness()
        let alive = live.cond
        Thread {
            while true {
                alive.lock()
                _ = alive.wait(until: Date().addingTimeInterval(25))
                let finished = live.done
                let stale = Date().timeIntervalSince(live.lastPong) > 80
                alive.unlock()
                if finished { return }
                if stale { ws.close(); return }
                try? ws.send(.text("ping"))
            }
        }.start()
        defer {
            alive.lock(); live.done = true; alive.broadcast(); alive.unlock()
            ws.close()
        }

        while true {
            let msg = try ws.receive()
            guard case .text(let text) = msg else { throw WebSocketError.protocolViolation("制御チャネルにバイナリ") }
            if text == "pong" {
                alive.lock(); live.lastPong = Date(); alive.unlock()
                continue
            }
            guard text.utf8.count <= 512,
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            incoming(obj, http: false, onIncoming)
        }
    }

    // MARK: HTTP (ロングポーリング)

    private func serveHTTP(_ onIncoming: @escaping (Transport) -> Void) throws {
        let client: HTTPClient
        do {
            client = try HTTPClient(base: relay)
        } catch {
            throw ConnectFailed(underlying: error)
        }
        // この起動ごとの ID。中継サーバーは、同じ部屋を別の RDHost (二重起動) が取ろうとしたのを見分ける
        var rng = SystemRandomNumberGenerator()
        let hid = Fingerprint.hex((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
        // トークンは URL に入れず本文で送る (アクセスログに残さないため)
        let body = Array("{\"t\":\"auth\",\"token\":\"\(Fingerprint.hex(token))\",\"hid\":\"\(hid)\"}".utf8)
        var isUp = false
        while !isStopped {
            let status: Int
            let resp: [UInt8]
            do {
                // サーバーは最長 20 秒待たせてから返す
                (status, resp) = try client.request("POST", path: "/h/host", query: ["room": room], body: body,
                                                    timeout: 40)
            } catch {
                throw isUp ? error : ConnectFailed(underlying: error)
            }
            switch status {
            case 200: break
            case 403: throw RelayError.badToken
            case 409: throw RelayError.roomInUse
            case 429: throw RelayError.busy
            default: throw isUp ? RelayError.status(status) : ConnectFailed(underlying: RelayError.status(status))
            }
            if !isUp {
                isUp = true
                up("http")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(resp)) as? [String: Any],
                  let events = obj["events"] as? [[String: Any]] else {
                throw HTTPError.protocolViolation("イベントの形式が不正")
            }
            for e in events.prefix(16) { incoming(e, http: true, onIncoming) }
        }
    }

    // MARK: 共通

    /// 「ビューアが来た」通知を受けて、そのセッションを受け取る
    private func incoming(_ obj: [String: Any], http: Bool, _ onIncoming: @escaping (Transport) -> Void) {
        guard obj["t"] as? String == "incoming",
              let id = obj["id"] as? String, id.count == 32,
              id.allSatisfy({ $0.isHexDigit }) else { return }
        // ip は中継サーバーの申告 (信用はしない。レート制限のキーにだけ使う)
        let ip = sanitize((obj["ip"] as? String) ?? "?", maxLength: 64)
        let relay = self.relay, room = self.room, log = self.log
        Thread {
            do {
                if http {
                    onIncoming(try HTTPRelayTransport.accept(relay: relay, room: room, id: id, peerIP: ip))
                } else {
                    let url = try RelayRoom.url(relay, path: "/accept", query: ["room": room, "id": id])
                    let dws = try WebSocketClient.connect(url)
                    onIncoming(RelayTransport(ws: dws, peer: "relay:\(ip)", peerIP: "relay:\(ip)"))
                }
            } catch {
                log("RELAY_ACCEPT_FAIL error=\(error)")
            }
        }.start()
    }
}
