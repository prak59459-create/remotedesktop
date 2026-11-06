import Foundation

// 中継サーバーを「普通の HTTP リクエスト」だけで使う通り道 (relay/server.js の /h/*)。
// WebSocket を通さないプロキシや社内ネットワーク、WebSocket を切ってしまう回線向け。
//
//   上り: POST /h/send?leg=L&seq=N を 1 本ずつ順に送る (送りたいデータをまとめて 1 回で送る)。
//         同じ N の再送はサーバーが無視するので、応答が届かなければ同じ N で送り直せる。
//   下り: GET /h/recv?leg=L&mode=stream を開いたままにして [u32 長さ][データ] を受け取る。
//         途中のプロキシが応答を溜め込む経路では最初の生存確認が届かないので、
//         そのときは GET /h/recv?mode=poll (ロングポーリング) に切り替える。
//         サーバーは /h/ready を受けるまでストリームにデータを流さないので、切り替えで取りこぼしは無い。
//
// ここを流れるのは Noise の暗号文だけ。中継サーバーや途中のプロキシがデータを消したり並べ替えたりしても、
// Noise が検出して切断する (盗み見や改ざんはできない)。

/// 下りストリームのフレーム ([u32 長さ][データ]、長さ 0 = 生存確認、0xFFFFFFFF = 切断)
public enum HTTPRelayFrame: Equatable {
    case keepalive
    case data([UInt8])
    case closed
}

/// 下りストリームの解析 (中継サーバーは信用しないので、長さは上限付き。ファジング対象)
public struct HTTPRelayFrameParser {
    public static let maxFrame = 2 * 1024 * 1024
    private var buffer: [UInt8] = []
    private var offset = 0

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) {
        if offset > 0 && (offset == buffer.count || offset >= 1 << 20) {
            buffer.removeFirst(offset)
            offset = 0
        }
        buffer += bytes
    }

    /// 次のフレーム。まだ揃っていなければ nil
    public mutating func next() throws -> HTTPRelayFrame? {
        guard buffer.count - offset >= 4 else { return nil }
        let n = Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16 | Int(buffer[offset + 2]) << 8
            | Int(buffer[offset + 3])
        if n == 0xFFFF_FFFF {
            offset += 4
            return .closed
        }
        if n == 0 {
            offset += 4
            return .keepalive
        }
        guard n <= Self.maxFrame else { throw HTTPError.protocolViolation("フレームが大きすぎます") }
        guard buffer.count - offset - 4 >= n else { return nil }
        let d = Array(buffer[offset + 4 ..< offset + 4 + n])
        offset += 4 + n
        return .data(d)
    }
}

public enum RelayError: Error, CustomStringConvertible {
    case hostOffline
    case busy
    case badToken
    case roomInUse
    case status(Int)

    public var description: String {
        switch self {
        case .hostOffline: return "中継サーバー: PC がオンラインではありません (RDHost が --relay 付きで動いているか確認してください)"
        case .busy: return "中継サーバーが混み合っています。少し待ってから試してください"
        case .badToken: return "中継サーバー: 部屋のトークンが一致しません"
        case .roomInUse: return "中継サーバー: 同じ部屋で別の RDHost が待ち受けています (二重起動?)"
        case .status(let s): return "中継サーバーの応答が不正です (HTTP \(s))"
        }
    }
}

public final class HTTPRelayTransport: Transport {
    public let peerDescription: String
    public let peerIP: String
    public var isLocalNetwork: Bool { false }

    private let client: HTTPClient
    private let leg: String
    private let inbox = ByteInbox()

    private let out = NSCondition()
    private var pending: [UInt8] = []
    private var closed = false // こちらから閉じた
    private var failed = false // 通り道が切れた
    private var stream: HTTPResponse?

    static let maxBatch = 256 * 1024
    static let maxPending = 4 * 1024 * 1024
    /// ストリームの最初の生存確認を待つ時間。これを過ぎたら溜め込む経路とみなして poll に切り替える
    public static var probeTimeout = 8.0
    /// ストリームのデータが途切れてもよい時間 (サーバーは 15 秒ごとに生存確認を送る)
    static let streamIdleTimeout = 45.0
    /// テスト用: ストリームを使わず最初から poll
    public static var forcePoll = false

    init(client: HTTPClient, leg: String, peer: String, peerIP: String) {
        self.client = client
        self.leg = leg
        peerDescription = peer
        self.peerIP = peerIP
        Thread { [self] in readLoop() }.start()
        Thread { [self] in sendLoop() }.start()
    }

    private var isClosed: Bool {
        out.lock(); defer { out.unlock() }
        return closed
    }

    /// 通り道が切れた (送信も止める)
    private func fail() {
        out.lock()
        failed = true
        let s = stream
        stream = nil
        out.broadcast()
        out.unlock()
        s?.cancel()
        inbox.finish()
    }

    // MARK: 下り

    private func readLoop() {
        defer {
            // こちらから閉じたときは、送信側が残りを送り切ってから閉じる
            if isClosed { inbox.finish() } else { fail() }
        }
        if !Self.forcePoll {
            guard streamLoop() else { return }
        }
        pollLoop()
    }

    /// ストリームで受信する。poll に切り替えるべきなら true
    private func streamLoop() -> Bool {
        let r: HTTPResponse
        do {
            r = try client.open("GET", path: "/h/recv", query: ["leg": leg, "mode": "stream"], timeout: Self.probeTimeout)
        } catch {
            return !isClosed
        }
        guard r.status == 200 else {
            r.cancel()
            return r.status != 410 && !isClosed
        }
        out.lock()
        if closed {
            out.unlock()
            r.cancel()
            return false
        }
        stream = r
        out.unlock()

        var parser = HTTPRelayFrameParser()
        var confirmed = false
        let probeDeadline = Date().addingTimeInterval(Self.probeTimeout)
        while true {
            let wait = confirmed ? Self.streamIdleTimeout : max(0.1, probeDeadline.timeIntervalSinceNow)
            let chunk: [UInt8]
            do {
                chunk = try r.read(timeout: wait)
            } catch {
                r.cancel()
                return !confirmed && !isClosed
            }
            if chunk.isEmpty {
                r.cancel()
                return !confirmed && !isClosed
            }
            parser.feed(chunk)
            while true {
                let frame: HTTPRelayFrame?
                do { frame = try parser.next() } catch { r.cancel(); return false }
                guard let f = frame else { break }
                switch f {
                case .keepalive:
                    if !confirmed {
                        confirmed = true
                        // 溜め込まれずに届いた。サーバーにデータを流し始めてもらう
                        guard let ready = try? client.request("POST", path: "/h/ready", query: ["leg": leg],
                                                              body: [], timeout: 15),
                              ready.status == 204 else {
                            r.cancel()
                            return false
                        }
                    }
                case .data(let d):
                    if !inbox.append(d) {
                        r.cancel()
                        return false
                    }
                case .closed:
                    r.cancel()
                    return false
                }
            }
        }
    }

    private func pollLoop() {
        var seq = 1
        var failures = 0
        while !isClosed {
            do {
                let (status, body) = try client.request("GET", path: "/h/recv",
                                                        query: ["leg": leg, "mode": "poll", "seq": String(seq)],
                                                        timeout: 40, limit: 2 * 1024 * 1024)
                guard status == 200 else { return } // 410 = 切断
                failures = 0
                if !body.isEmpty && !inbox.append(body) { return }
                seq += 1
            } catch {
                // 同じ番号で取り直す (サーバーは同じ中身を返す)
                failures += 1
                if failures > 3 || isClosed { return }
                Thread.sleep(forTimeInterval: 0.5 * Double(failures))
            }
        }
    }

    // MARK: 上り

    private func sendLoop() {
        var seq = 0
        while true {
            out.lock()
            while pending.isEmpty && !closed && !failed { out.wait() }
            if failed {
                out.unlock()
                return
            }
            if pending.isEmpty && closed {
                out.unlock()
                // 送り切ってから閉じる
                _ = try? client.request("POST", path: "/h/close", query: ["leg": leg], body: [], timeout: 10)
                return
            }
            let n = min(pending.count, Self.maxBatch)
            let batch = Array(pending[0 ..< n])
            pending.removeFirst(n)
            out.broadcast()
            out.unlock()

            seq += 1
            var attempt = 0
            while true {
                do {
                    let (status, _) = try client.request("POST", path: "/h/send",
                                                         query: ["leg": leg, "seq": String(seq)], body: batch,
                                                         timeout: 30)
                    if status == 204 || status == 200 { break }
                    fail()
                    return
                } catch {
                    attempt += 1
                    if attempt >= 3 {
                        fail()
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.3 * Double(attempt))
                }
            }
        }
    }

    // MARK: Transport

    public func setReceiveTimeout(_ seconds: Double) {
        inbox.setTimeout(seconds)
    }

    public func sendAll(_ bytes: [UInt8]) throws {
        out.lock()
        defer { out.unlock() }
        while pending.count > Self.maxPending && !failed && !closed { out.wait() }
        if failed || closed { throw NetError.closed }
        pending += bytes
        out.broadcast()
    }

    public func receive(exactly n: Int) throws -> [UInt8] {
        do {
            return try inbox.receive(exactly: n)
        } catch is ByteInbox.Timeout {
            close()
            throw NetError.io("受信タイムアウト")
        }
    }

    public func close() {
        out.lock()
        if closed {
            out.unlock()
            return
        }
        closed = true
        let s = stream
        stream = nil
        out.broadcast()
        out.unlock()
        s?.cancel()
        inbox.finish()
    }

    // MARK: 接続

    static func parseLeg(_ body: [UInt8]) -> String? {
        guard body.count <= 256,
              let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
              let leg = obj["leg"] as? String, leg.count == 32, leg.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        return leg
    }

    static func check(_ status: Int) throws {
        switch status {
        case 200: return
        case 404: throw RelayError.hostOffline
        case 429: throw RelayError.busy
        case 403: throw RelayError.badToken
        case 409: throw RelayError.roomInUse
        default: throw RelayError.status(status)
        }
    }

    /// ビューア側: 中継サーバー経由でホストの部屋に接続する
    public static func connect(relay: URL, room: String) throws -> HTTPRelayTransport {
        let client = try HTTPClient(base: relay)
        let (status, body) = try client.request("POST", path: "/h/connect", query: ["room": room], body: [], timeout: 20)
        try check(status)
        guard let leg = parseLeg(body) else { throw HTTPError.protocolViolation("leg がありません") }
        return HTTPRelayTransport(client: client, leg: leg, peer: "relay-http:\(relay.host ?? "?")", peerIP: "relay")
    }

    /// ホスト側: 通知されたセッションを受け取る
    static func accept(relay: URL, room: String, id: String, peerIP: String) throws -> HTTPRelayTransport {
        let client = try HTTPClient(base: relay)
        let (status, body) = try client.request("POST", path: "/h/accept", query: ["room": room, "id": id], body: [],
                                                timeout: 20)
        try check(status)
        guard let leg = parseLeg(body) else { throw HTTPError.protocolViolation("leg がありません") }
        return HTTPRelayTransport(client: client, leg: leg, peer: "relay-http:\(peerIP)", peerIP: "relay:\(peerIP)")
    }
}

/// ファジング用の入口 (RDFuzz から使う)
public enum HTTPRelayFrameFuzz {
    public static func run(_ data: [UInt8]) {
        var p = HTTPRelayFrameParser()
        var i = 0
        // 任意の位置で区切って与える
        while i < data.count {
            let n = min(data.count - i, Int(data[i] % 32) + 1)
            p.feed(Array(data[i ..< i + n]))
            i += n
            while let f = try? p.next() {
                if f == .closed { return }
            }
        }
    }
}
