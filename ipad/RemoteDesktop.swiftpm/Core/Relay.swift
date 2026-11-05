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

/// WebSocket を Transport (バイトストリーム) として使う。受信は専用スレッドで読み、タイムアウトを扱えるようにする。
public final class RelayTransport: Transport {
    public let peerDescription: String
    public let peerIP: String
    public var isLocalNetwork: Bool { false }

    private let ws: WebSocketConnection
    private let cond = NSCondition()
    private var buffer: [UInt8] = []
    private var offset = 0
    private var finished = false
    private var timeout: Double = 0
    static let maxBuffered = 32 * 1024 * 1024

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
            cond.lock()
            // 読み終えた部分を捨てる (受信側が少しでも遅れていると、ここで詰めないと際限なく増える)
            if offset > 0 && (offset == buffer.count || offset >= 1 << 20) {
                buffer.removeFirst(offset)
                offset = 0
            }
            buffer += b
            let over = buffer.count - offset > Self.maxBuffered
            cond.broadcast()
            cond.unlock()
            if over { break }
        }
        cond.lock()
        finished = true
        cond.broadcast()
        cond.unlock()
        ws.close()
    }

    public func setReceiveTimeout(_ seconds: Double) {
        cond.lock(); timeout = seconds; cond.unlock()
    }

    public func sendAll(_ bytes: [UInt8]) throws {
        try ws.send(.binary(bytes))
    }

    public func receive(exactly n: Int) throws -> [UInt8] {
        cond.lock()
        defer { cond.unlock() }
        let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : nil
        while buffer.count - offset < n {
            if finished { throw NetError.closed }
            if let d = deadline {
                if !cond.wait(until: d) && buffer.count - offset < n {
                    ws.close()
                    throw NetError.io("受信タイムアウト")
                }
            } else {
                cond.wait()
            }
        }
        let out = Array(buffer[offset ..< offset + n])
        offset += n
        return out
    }

    public func close() { ws.close() }

    // MARK: ビューア側

    /// 中継サーバー経由でホストの部屋に接続する
    public static func connect(relay: URL, room: String) throws -> RelayTransport {
        let url = try RelayRoom.url(relay, path: "/connect", query: ["room": room])
        let ws = try WebSocketClient.connect(url)
        return RelayTransport(ws: ws, peer: "relay:\(relay.host ?? "?")", peerIP: "relay")
    }
}

/// ホスト側: 中継サーバーに待ち受けを登録し、ビューアが来たら Transport を渡す。切れたら自動で再接続する。
public final class RelayHostListener {
    public let relay: URL
    public let room: String
    private let log: (String) -> Void
    private var stopped = false
    private let lock = NSLock()
    private var control: WebSocketConnection?

    private let token: [UInt8]

    public init(relay: URL, roomToken: [UInt8], log: @escaping (String) -> Void) {
        self.relay = relay
        token = roomToken
        room = RelayRoom.id(token: roomToken)
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
        var backoff = 2.0
        while !isStopped {
            do {
                let ws = try WebSocketClient.connect(try RelayRoom.url(relay, path: "/host", query: ["room": room]))
                // トークンは URL に入れない (中継サーバーやプロキシのアクセスログに残さないため)
                try ws.send(.text("{\"t\":\"auth\",\"token\":\"\(Fingerprint.hex(token))\"}"))
                lock.lock(); control = ws; lock.unlock()
                log("RELAY_UP relay=\(relay.host ?? "?")")
                backoff = 2
                try serve(ws, onIncoming: onIncoming)
            } catch {
                if isStopped { break }
                log("RELAY_DOWN error=\(error) retry_in=\(Int(backoff))s")
            }
            lock.lock(); control = nil; lock.unlock()
            if isStopped { break }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 60)
        }
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
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  obj["t"] as? String == "incoming",
                  let id = obj["id"] as? String, id.count == 32,
                  id.allSatisfy({ $0.isHexDigit }) else { continue }
            // ip は中継サーバーの申告 (信用はしない。レート制限のキーにだけ使う)
            let ip = sanitize((obj["ip"] as? String) ?? "?", maxLength: 64)
            let relay = self.relay, room = self.room, log = self.log
            Thread {
                do {
                    let url = try RelayRoom.url(relay, path: "/accept", query: ["room": room, "id": id])
                    let dws = try WebSocketClient.connect(url)
                    onIncoming(RelayTransport(ws: dws, peer: "relay:\(ip)", peerIP: "relay:\(ip)"))
                } catch {
                    log("RELAY_ACCEPT_FAIL error=\(error)")
                }
            }.start()
        }
    }
}
