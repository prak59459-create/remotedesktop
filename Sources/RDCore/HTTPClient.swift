import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import CWinSys
import WinSDK
#endif

// 中継サーバーとの HTTP 通信に使う、最小限のブロッキング HTTP クライアント。
// 応答の本文を少しずつ読めるので、閉じずに流し続ける応答 (ストリーム) も扱える。
//   macOS / iPadOS: URLSession (TLS とプロキシは OS が処理)
//   Windows:        WinHTTP (TLS とシステムのプロキシ設定は OS が処理)
//   その他:         HTTP/1.1 の最小実装 (http:// のみ。開発・テスト用)
//
// 中身は Noise で暗号化済み。TLS は「中継サーバーへの経路を守る」追加の層。

public enum HTTPError: Error, CustomStringConvertible {
    case badURL(String)
    case request(String)
    case timeout
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .badURL(let s): return "URL が不正です: \(s)"
        case .request(let s): return "HTTP 接続に失敗: \(s)"
        case .timeout: return "HTTP の応答がありません (タイムアウト)"
        case .protocolViolation(let s): return "HTTP の応答が不正: \(s)"
        }
    }
}

/// 読み途中の応答
public protocol HTTPResponse: AnyObject {
    var status: Int { get }
    /// 届いている本文を返す (無ければ timeout 秒まで待つ)。本文の終わりなら空配列。
    func read(timeout: Double) throws -> [UInt8]
    /// 中断する (別スレッドの read も終わらせる)
    func cancel()
}

extension HTTPResponse {
    /// 本文をすべて読む (limit バイトを超えたら打ち切ってエラー)
    public func readAll(limit: Int, timeout: Double) throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let chunk = try read(timeout: timeout)
            if chunk.isEmpty { return out }
            out += chunk
            if out.count > limit {
                cancel()
                throw HTTPError.protocolViolation("応答が大きすぎます")
            }
        }
    }
}

/// 1 つの中継サーバーに対する HTTP クライアント。接続はできるだけ使い回す。
public final class HTTPClient {
    public let base: URL
    #if canImport(Darwin)
    private let session: URLSession
    #elseif os(Windows)
    private let win: WinHTTPSession
    #endif

    /// base は https:// (開発用に http://) の URL。wss:// / ws:// も受け付ける
    public init(base: URL) throws {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false), base.host != nil else {
            throw HTTPError.badURL(base.absoluteString)
        }
        switch c.scheme?.lowercased() {
        case "https", "wss": c.scheme = "https"
        case "http", "ws": c.scheme = "http"
        default: throw HTTPError.badURL(base.absoluteString)
        }
        if c.path.hasSuffix("/") { c.path = String(c.path.dropLast()) }
        c.query = nil
        guard let u = c.url else { throw HTTPError.badURL(base.absoluteString) }
        self.base = u
        #if canImport(Darwin)
        let config = URLSessionConfiguration.ephemeral // Cookie やキャッシュを残さない
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: config)
        #elseif os(Windows)
        win = try WinHTTPSession(url: u)
        #else
        guard c.scheme == "http" else { throw HTTPError.badURL("この OS では https:// を使えません (開発用ビルド)") }
        #endif
    }

    deinit {
        #if canImport(Darwin)
        session.invalidateAndCancel()
        #endif
    }

    /// base + path?query の URL
    func url(path: String, query: [String: String]) throws -> URL {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw HTTPError.badURL(base.absoluteString)
        }
        c.path += path
        c.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = c.url else { throw HTTPError.badURL(base.absoluteString) }
        return u
    }

    /// リクエストを送り、応答ヘッダーが届くまで待つ (最大 timeout 秒)
    public func open(_ method: String, path: String, query: [String: String] = [:], body: [UInt8]? = nil,
                     timeout: Double) throws -> HTTPResponse {
        let u = try url(path: path, query: query)
        #if canImport(Darwin)
        return try URLSessionHTTPResponse(session: session, url: u, method: method, body: body, timeout: timeout)
        #elseif os(Windows)
        return try win.open(method: method, url: u, body: body, timeout: timeout)
        #else
        return try PlainHTTPResponse(url: u, method: method, body: body, timeout: timeout)
        #endif
    }

    /// リクエストを送り、本文をすべて読む
    public func request(_ method: String, path: String, query: [String: String] = [:], body: [UInt8]? = nil,
                        timeout: Double, limit: Int = 64 * 1024) throws -> (status: Int, body: [UInt8]) {
        let r = try open(method, path: path, query: query, body: body, timeout: timeout)
        defer { r.cancel() }
        let b = try r.readAll(limit: limit, timeout: timeout)
        return (r.status, b)
    }
}

/// 届いた本文を貯めて、read で渡す (URLSession の受信を同期 API にするため)
private final class BodyBuffer {
    let cond = NSCondition()
    var chunks: [[UInt8]] = []
    var finished = false
    var error: Error?

    func push(_ b: [UInt8]) {
        cond.lock(); chunks.append(b); cond.broadcast(); cond.unlock()
    }

    func finish(_ e: Error?) {
        cond.lock()
        if !finished {
            finished = true
            error = e
        }
        cond.broadcast()
        cond.unlock()
    }

    func read(timeout: Double, onTimeout: () -> Void) throws -> [UInt8] {
        cond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while chunks.isEmpty && !finished {
            if !cond.wait(until: deadline) && chunks.isEmpty && !finished {
                cond.unlock()
                onTimeout()
                throw HTTPError.timeout
            }
        }
        defer { cond.unlock() }
        if !chunks.isEmpty { return chunks.removeFirst() }
        if let e = error { throw e }
        return []
    }
}

// MARK: - Apple (URLSession)

#if canImport(Darwin)
private final class URLSessionHTTPResponse: NSObject, HTTPResponse, URLSessionDataDelegate {
    private(set) var status = 0
    private var task: URLSessionDataTask!
    private let headers = DispatchSemaphore(value: 0)
    private let buffer = BodyBuffer()
    private let lock = NSLock()
    private var gotHeaders = false

    init(session: URLSession, url: URL, method: String, body: [UInt8]?, timeout: Double) throws {
        super.init()
        var req = URLRequest(url: url)
        req.httpMethod = method
        // 応答のデータが途切れてもよい最長時間 (ストリームでは生存確認がこれより短い間隔で届く)
        req.timeoutInterval = max(timeout, 1)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let b = body {
            req.httpBody = Data(b)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        task = session.dataTask(with: req)
        task.delegate = self // iOS 15 / macOS 12 以降: このタスクの受信をここで受ける
        task.resume()
        guard headers.wait(timeout: .now() + max(timeout, 1)) == .success else {
            task.cancel()
            throw HTTPError.timeout
        }
        lock.lock()
        let ok = gotHeaders
        lock.unlock()
        if !ok {
            buffer.cond.lock()
            let e = buffer.error
            buffer.cond.unlock()
            throw HTTPError.request(e.map { "\($0.localizedDescription)" } ?? "応答なし")
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        gotHeaders = true
        lock.unlock()
        completionHandler(.allow)
        headers.signal()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.push([UInt8](data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        buffer.finish(error.map { HTTPError.request($0.localizedDescription) })
        headers.signal() // ヘッダー前に失敗した場合
    }

    func read(timeout: Double) throws -> [UInt8] {
        try buffer.read(timeout: timeout) { task.cancel() }
    }

    func cancel() {
        task.cancel()
        buffer.finish(NetError.closed)
    }
}
#endif

// MARK: - Windows (WinHTTP)

#if os(Windows)
final class WinHTTPSession {
    private let session: HINTERNET
    private let connection: HINTERNET
    private let secure: Bool

    init(url: URL) throws {
        secure = url.scheme?.lowercased() == "https"
        let host = url.host!
        let port = UInt16(url.port ?? (secure ? 443 : 80))
        // WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4 (システムのプロキシ設定に従う)
        guard let s = winString("RemoteDesktop/2", { WinHttpOpen($0, 4, nil, nil, 0) }) else {
            throw HTTPError.request("WinHttpOpen (error \(GetLastError()))")
        }
        // TLS 1.2 以上だけを許可 (WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | TLS1_3)
        var protocols: DWORD = 0x0000_0800 | 0x0000_2000
        _ = WinHttpSetOption(s, 84 /* WINHTTP_OPTION_SECURE_PROTOCOLS */, &protocols, DWORD(MemoryLayout<DWORD>.size))
        // HTTP/2 が使えれば使う (1 本の接続に多重化できる)。WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL = 133, HTTP2 = 1
        var h2: DWORD = 0x1
        _ = WinHttpSetOption(s, 133, &h2, DWORD(MemoryLayout<DWORD>.size))
        guard let c = winString(host, { WinHttpConnect(s, $0, port, 0) }) else {
            WinHttpCloseHandle(s)
            throw HTTPError.request("WinHttpConnect \(host) (error \(GetLastError()))")
        }
        session = s
        connection = c
    }

    deinit {
        WinHttpCloseHandle(connection)
        WinHttpCloseHandle(session)
    }

    func open(method: String, url: URL, body: [UInt8]?, timeout: Double) throws -> HTTPResponse {
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        let flags: DWORD = secure ? 0x0080_0000 /* WINHTTP_FLAG_SECURE */ : 0
        // WINHTTP_FLAG_REFRESH (0x100): キャッシュを使わない
        guard let r = winString(method, { verb in winString(path, { p in
            WinHttpOpenRequest(connection, verb, p, nil, nil, nil, flags | 0x100)
        }) }) else {
            throw HTTPError.request("WinHttpOpenRequest (error \(GetLastError()))")
        }
        let ms = Int32(min(max(timeout, 1), 3600) * 1000)
        _ = WinHttpSetTimeouts(r, 15000, 15000, 30000, ms)
        // 証明書検証はデフォルト (有効) のまま。無効化するオプションは使わない。
        var payload = body ?? []
        let headers = body != nil ? "Content-Type: application/octet-stream\r\n" : ""
        let sent = winString(headers) { h in
            payload.withUnsafeMutableBytes { p in
                WinHttpSendRequest(r, headers.isEmpty ? nil : h, headers.isEmpty ? 0 : DWORD(headers.utf16.count),
                                   p.count == 0 ? nil : p.baseAddress, DWORD(p.count), DWORD(p.count), 0)
            }
        }
        guard sent, WinHttpReceiveResponse(r, nil) else {
            let e = GetLastError()
            WinHttpCloseHandle(r)
            if e == 12002 /* ERROR_WINHTTP_TIMEOUT */ { throw HTTPError.timeout }
            throw HTTPError.request("\(url.host ?? "?"): 接続できません (WinHTTP error \(e))")
        }
        var status: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        _ = WinHttpQueryHeaders(r, DWORD(19) | 0x2000_0000 /* STATUS_CODE | FLAG_NUMBER */, nil, &status, &size, nil)
        return WinHTTPResponse(request: r, status: Int(status))
    }
}

private func winString<T>(_ s: String, _ body: (UnsafePointer<UInt16>) -> T) -> T {
    s.withCString(encodedAs: UTF16.self, body)
}

/// WinHTTP の同期 API は、別スレッドで使用中のハンドルを閉じると危ない (閉じた番号は再利用されうる)。
/// cancel() は印を付けるだけにして、読んでいるスレッドが戻ってきてから閉じる。
private final class WinHTTPResponse: HTTPResponse {
    let status: Int
    private let request: HINTERNET
    private let state = NSLock()
    private var cancelled = false
    private var reading = false
    private var handleClosed = false

    init(request: HINTERNET, status: Int) {
        self.request = request
        self.status = status
    }

    deinit {
        cancel()
    }

    func read(timeout: Double) throws -> [UInt8] {
        state.lock()
        if cancelled {
            state.unlock()
            throw NetError.closed
        }
        reading = true
        state.unlock()
        let ms = Int32(min(max(timeout, 1), 3600) * 1000)
        _ = WinHttpSetTimeouts(request, 15000, 15000, 30000, ms)
        // QueryDataAvailable は「何バイトか届くまで」待つ。ReadData を直接呼ぶとバッファが埋まるまで待つことがある
        var available: DWORD = 0
        var out: [UInt8] = []
        var failure: DWORD = 0
        if WinHttpQueryDataAvailable(request, &available) {
            if available > 0 {
                out = [UInt8](repeating: 0, count: Int(min(available, 256 * 1024)))
                var got: DWORD = 0
                let ok = out.withUnsafeMutableBytes { WinHttpReadData(request, $0.baseAddress, DWORD($0.count), &got) }
                if ok { out.removeSubrange(Int(got)...) } else { failure = GetLastError() }
            }
        } else {
            failure = GetLastError()
        }
        state.lock()
        reading = false
        let mustClose = cancelled && !handleClosed
        if mustClose { handleClosed = true }
        state.unlock()
        if mustClose {
            WinHttpCloseHandle(request)
            throw NetError.closed
        }
        if failure == 12002 /* ERROR_WINHTTP_TIMEOUT */ {
            cancel()
            throw HTTPError.timeout
        }
        if failure != 0 {
            cancel()
            throw HTTPError.request("受信 (WinHTTP error \(failure))")
        }
        return out
    }

    func cancel() {
        state.lock()
        if cancelled {
            state.unlock()
            return
        }
        cancelled = true
        let idle = !reading
        if idle { handleClosed = true }
        state.unlock()
        if idle { WinHttpCloseHandle(request) }
    }
}
#endif

// MARK: - 最小実装 (平文 http://)

#if !canImport(Darwin) && !os(Windows)
private final class PlainHTTPResponse: HTTPResponse {
    let status: Int
    private let tcp: TCPConnection
    private var chunked = false
    private var remaining = -1 // Content-Length の残り (-1 = 指定なし)
    private var done = false
    private let lock = NSLock()

    init(url: URL, method: String, body: [UInt8]?, timeout: Double) throws {
        let host = url.host!
        let port = UInt16(url.port ?? 80)
        tcp = try TCPConnection.open(host: host, port: port)
        tcp.setReceiveTimeout(max(timeout, 1))
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        var req = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n"
        if let b = body {
            req += "Content-Type: application/octet-stream\r\nContent-Length: \(b.count)\r\n"
        } else if method == "POST" {
            req += "Content-Length: 0\r\n"
        }
        req += "\r\n"
        try tcp.sendAll(Array(req.utf8) + (body ?? []))

        var head: [UInt8] = []
        do {
            while !(head.count >= 4 && head.suffix(4) == [13, 10, 13, 10]) {
                guard head.count < 16384 else { throw HTTPError.protocolViolation("応答ヘッダーが長すぎます") }
                head += try tcp.receive(exactly: 1)
            }
        } catch NetError.io {
            tcp.close()
            throw HTTPError.timeout
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]) else {
            tcp.close()
            throw HTTPError.protocolViolation(lines.first ?? "応答なし")
        }
        status = code
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "transfer-encoding": chunked = kv[1].lowercased().contains("chunked")
            case "content-length": remaining = Int(kv[1]) ?? -1
            default: break
            }
        }
        if !chunked && remaining == 0 { done = true }
    }

    deinit { tcp.close() }

    private func line() throws -> String {
        var b: [UInt8] = []
        while !(b.count >= 2 && b.suffix(2) == [13, 10]) {
            guard b.count < 1024 else { throw HTTPError.protocolViolation("チャンクの行が長すぎます") }
            b += try tcp.receive(exactly: 1)
        }
        return String(decoding: b.dropLast(2), as: UTF8.self)
    }

    func read(timeout: Double) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        if done { return [] }
        tcp.setReceiveTimeout(max(timeout, 1))
        do {
            if chunked {
                let sizeText = try line().split(separator: ";").first.map(String.init) ?? ""
                guard let n = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), n >= 0, n <= 16 << 20 else {
                    throw HTTPError.protocolViolation("チャンクの長さが不正")
                }
                if n == 0 {
                    done = true
                    tcp.close()
                    return []
                }
                let data = try tcp.receive(exactly: n)
                _ = try tcp.receive(exactly: 2)
                return data
            }
            if remaining > 0 {
                let n = min(remaining, 64 * 1024)
                let data = try tcp.receive(exactly: n)
                remaining -= n
                if remaining == 0 { done = true }
                return data
            }
            // 長さの指定がない: 切断まで (1 バイトずつは遅いが開発用)
            do {
                return try tcp.receive(exactly: 1)
            } catch NetError.closed {
                done = true
                return []
            }
        } catch NetError.io {
            tcp.close()
            throw HTTPError.timeout
        }
    }

    func cancel() { tcp.close() }
}
#endif
