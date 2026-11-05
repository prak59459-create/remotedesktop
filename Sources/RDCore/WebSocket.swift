import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import CWinSys
import WinSDK
#endif

// 中継サーバーとの通信に使う WebSocket クライアント (ブロッキング API)。
//   macOS / iPadOS: URLSessionWebSocketTask (TLS は OS が処理)
//   Windows:        WinHTTP の WebSocket API (TLS は OS が処理)
//   その他:         RFC 6455 の最小実装 (ws:// のみ。開発・テスト用)
//
// どの経路でも中身は Noise で暗号化済み。TLS は「中継サーバーへの経路を守る」追加の層。

public enum WebSocketMessage: Equatable {
    case binary([UInt8])
    case text(String)
}

public protocol WebSocketConnection: AnyObject {
    func send(_ message: WebSocketMessage) throws
    /// 次のメッセージを待つ。切断されたら NetError.closed
    func receive() throws -> WebSocketMessage
    func close()
}

public enum WebSocketError: Error, CustomStringConvertible {
    case badURL(String)
    case handshake(String)
    case unsupported(String)
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .badURL(let s): return "URL が不正です: \(s)"
        case .handshake(let s): return "WebSocket 接続に失敗: \(s)"
        case .unsupported(let s): return "未対応: \(s)"
        case .protocolViolation(let s): return "WebSocket のデータが不正: \(s)"
        }
    }
}

public enum WebSocketClient {
    public static let maxMessageSize = 1 << 20

    public static func connect(_ url: URL) throws -> WebSocketConnection {
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss", url.host != nil else {
            throw WebSocketError.badURL(url.absoluteString)
        }
        #if canImport(Darwin)
        return try URLSessionWebSocket(url: url)
        #elseif os(Windows)
        return try WinHTTPWebSocket(url: url)
        #else
        guard scheme == "ws" else { throw WebSocketError.unsupported("この OS では wss:// を使えません (開発用ビルド)") }
        return try PlainWebSocket(url: url)
        #endif
    }
}

// MARK: - 最小実装 (平文 ws://)

final class PlainWebSocket: WebSocketConnection {
    private let tcp: TCPConnection
    private let sendLock = NSLock()

    init(url: URL) throws {
        let host = url.host!
        let port = UInt16(url.port ?? 80)
        tcp = try TCPConnection.open(host: host, port: port)
        tcp.setReceiveTimeout(15)
        var rng = SystemRandomNumberGenerator()
        let key = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }).base64EncodedString()
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        let req = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try tcp.sendAll(Array(req.utf8))

        var head: [UInt8] = []
        while !(head.count >= 4 && head.suffix(4) == [13, 10, 13, 10]) {
            guard head.count < 8192 else { throw WebSocketError.handshake("応答ヘッダーが長すぎます") }
            head += try tcp.receive(exactly: 1)
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 101") else {
            throw WebSocketError.handshake(lines.first ?? "応答なし")
        }
        let expected = Data(Insecure.SHA1.hash(data: Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let accept = lines.first { $0.lowercased().hasPrefix("sec-websocket-accept:") }?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        guard accept == expected else { throw WebSocketError.handshake("Sec-WebSocket-Accept が一致しません") }
        tcp.setReceiveTimeout(0)
    }

    private func sendFrame(opcode: UInt8, _ payload: [UInt8]) throws {
        var f: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            f.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            f += [UInt8(0x80 | 126), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
        } else {
            f.append(0x80 | 127)
            for i in (0 ..< 8).reversed() { f.append(UInt8((UInt64(n) >> (8 * UInt64(i))) & 0xFF)) }
        }
        var rng = SystemRandomNumberGenerator()
        let mask = (0 ..< 4).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
        f += mask
        f.reserveCapacity(f.count + n)
        for (i, b) in payload.enumerated() { f.append(b ^ mask[i & 3]) }
        sendLock.lock(); defer { sendLock.unlock() }
        try tcp.sendAll(f)
    }

    func send(_ message: WebSocketMessage) throws {
        switch message {
        case .binary(let b): try sendFrame(opcode: 0x2, b)
        case .text(let s): try sendFrame(opcode: 0x1, Array(s.utf8))
        }
    }

    func receive() throws -> WebSocketMessage {
        do {
            return try Self.readMessage(next: { try tcp.receive(exactly: $0) },
                                        control: { op, payload in try sendFrame(opcode: op, payload) })
        } catch NetError.closed {
            tcp.close()
            throw NetError.closed
        }
    }

    /// サーバーから届くフレームを 1 メッセージ分読む (ファジング対象の純粋な解析部分)。
    /// next(n) は n バイトを返す。control は ping への pong や close の返送に使う。
    static func readMessage(next: (Int) throws -> [UInt8],
                            control: (UInt8, [UInt8]) throws -> Void) throws -> WebSocketMessage {
        var buffer: [UInt8] = []
        var messageOpcode: UInt8 = 0
        while true {
            let h = try next(2)
            let fin = h[0] & 0x80 != 0
            let opcode = h[0] & 0x0F
            guard h[0] & 0x70 == 0 else { throw WebSocketError.protocolViolation("予約ビットが立っています") }
            guard h[1] & 0x80 == 0 else { throw WebSocketError.protocolViolation("サーバーからのフレームがマスクされています") }
            var len = UInt64(h[1] & 0x7F)
            if len == 126 {
                let e = try next(2)
                len = UInt64(e[0]) << 8 | UInt64(e[1])
            } else if len == 127 {
                let e = try next(8)
                len = e.reduce(0) { $0 << 8 | UInt64($1) }
            }
            guard len <= UInt64(WebSocketClient.maxMessageSize),
                  buffer.count + Int(len) <= WebSocketClient.maxMessageSize else {
                throw WebSocketError.protocolViolation("メッセージが大きすぎます")
            }
            let isControl = opcode & 0x8 != 0
            if isControl {
                // 制御フレームは分割禁止・125 バイトまで (RFC 6455 5.5)
                guard fin, len <= 125 else { throw WebSocketError.protocolViolation("不正な制御フレーム") }
            }
            let payload = len > 0 ? try next(Int(len)) : []
            switch opcode {
            case 0x8: // close
                try? control(0x8, Array(payload.prefix(2)))
                throw NetError.closed
            case 0x9: // ping
                try control(0xA, payload)
                continue
            case 0xA: // pong
                continue
            case 0x0: // 続き
                guard messageOpcode != 0 else { throw WebSocketError.protocolViolation("不正な継続フレーム") }
            case 0x1, 0x2:
                guard messageOpcode == 0 else { throw WebSocketError.protocolViolation("フレームが入れ子です") }
                messageOpcode = opcode
            default:
                throw WebSocketError.protocolViolation("不明な opcode \(opcode)")
            }
            buffer += payload
            if fin {
                return messageOpcode == 0x1 ? .text(String(decoding: buffer, as: UTF8.self)) : .binary(buffer)
            }
        }
    }

    func close() {
        try? sendFrame(opcode: 0x8, [0x03, 0xE8])
        tcp.close()
    }
}

// MARK: - Apple (URLSessionWebSocketTask)

#if canImport(Darwin)
final class URLSessionWebSocket: NSObject, WebSocketConnection, URLSessionWebSocketDelegate {
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private let opened = DispatchSemaphore(value: 0)
    private var openError: Error?

    init(url: URL) throws {
        super.init()
        let config = URLSessionConfiguration.ephemeral // Cookie やキャッシュを残さない
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = WebSocketClient.maxMessageSize
        task.resume()
        guard opened.wait(timeout: .now() + 20) == .success, openError == nil else {
            task.cancel()
            session.invalidateAndCancel()
            throw WebSocketError.handshake(openError.map { "\($0.localizedDescription)" } ?? "タイムアウト")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        openError = error ?? NetError.closed
        opened.signal()
    }

    func send(_ message: WebSocketMessage) throws {
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        let m: URLSessionWebSocketTask.Message
        switch message {
        case .binary(let b): m = .data(Data(b))
        case .text(let s): m = .string(s)
        }
        task.send(m) { e in err = e; sem.signal() }
        sem.wait()
        if let e = err { throw NetError.io("WebSocket 送信: \(e.localizedDescription)") }
    }

    func receive() throws -> WebSocketMessage {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<URLSessionWebSocketTask.Message, Error>!
        task.receive { r in result = r; sem.signal() }
        sem.wait()
        switch result! {
        case .success(.data(let d)): return .binary([UInt8](d))
        case .success(.string(let s)): return .text(s)
        case .success: throw WebSocketError.protocolViolation("不明なメッセージ")
        case .failure: throw NetError.closed
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
#endif

// MARK: - Windows (WinHTTP)

#if os(Windows)
final class WinHTTPWebSocket: WebSocketConnection {
    private let session: HINTERNET
    private let connection: HINTERNET
    private let socket: HINTERNET
    private let sendLock = NSLock()
    private let closeLock = NSLock()
    private var closed = false

    init(url: URL) throws {
        let secure = url.scheme?.lowercased() == "wss"
        let host = url.host!
        let port = UInt16(url.port ?? (secure ? 443 : 80))
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }

        func w<T>(_ s: String, _ body: (UnsafePointer<UInt16>) -> T) -> T {
            s.withCString(encodedAs: UTF16.self, body)
        }
        // WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4 (システムのプロキシ設定に従う)
        guard let s = w("RemoteDesktop/2", { WinHttpOpen($0, 4, nil, nil, 0) }) else {
            throw WebSocketError.handshake("WinHttpOpen (error \(GetLastError()))")
        }
        // TLS 1.2 以上だけを許可 (WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | TLS1_3)
        var protocols: DWORD = 0x0000_0800 | 0x0000_2000
        _ = WinHttpSetOption(s, 84 /* WINHTTP_OPTION_SECURE_PROTOCOLS */, &protocols, DWORD(MemoryLayout<DWORD>.size))
        guard let c = w(host, { WinHttpConnect(s, $0, port, 0) }) else {
            WinHttpCloseHandle(s)
            throw WebSocketError.handshake("WinHttpConnect \(host) (error \(GetLastError()))")
        }
        let flags: DWORD = secure ? 0x0080_0000 /* WINHTTP_FLAG_SECURE */ : 0
        guard let r = w("GET", { verb in w(path, { p in WinHttpOpenRequest(c, verb, p, nil, nil, nil, flags) }) }) else {
            WinHttpCloseHandle(c); WinHttpCloseHandle(s)
            throw WebSocketError.handshake("WinHttpOpenRequest (error \(GetLastError()))")
        }
        defer { WinHttpCloseHandle(r) }
        // 証明書検証はデフォルト (有効) のまま。無効化するオプションは使わない。
        guard WinHttpSetOption(r, 114 /* WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET */, nil, 0),
              WinHttpSendRequest(r, nil, 0, nil, 0, 0, 0),
              WinHttpReceiveResponse(r, nil) else {
            let e = GetLastError()
            WinHttpCloseHandle(c); WinHttpCloseHandle(s)
            throw WebSocketError.handshake("\(host): 接続できません (WinHTTP error \(e))")
        }
        var status: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        _ = WinHttpQueryHeaders(r, DWORD(19) | 0x2000_0000 /* STATUS_CODE | FLAG_NUMBER */, nil, &status, &size, nil)
        guard status == 101, let ws = WinHttpWebSocketCompleteUpgrade(r, 0) else {
            WinHttpCloseHandle(c); WinHttpCloseHandle(s)
            throw WebSocketError.handshake("\(host): HTTP \(status)")
        }
        session = s
        connection = c
        socket = ws
    }

    deinit {
        close()
        WinHttpCloseHandle(connection)
        WinHttpCloseHandle(session)
    }

    func send(_ message: WebSocketMessage) throws {
        var bytes: [UInt8]
        let type: WINHTTP_WEB_SOCKET_BUFFER_TYPE
        switch message {
        case .binary(let b): bytes = b; type = WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE
        case .text(let s): bytes = Array(s.utf8); type = WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE
        }
        sendLock.lock(); defer { sendLock.unlock() }
        let rc = bytes.withUnsafeMutableBytes { WinHttpWebSocketSend(socket, type, $0.baseAddress, DWORD($0.count)) }
        if rc != 0 { throw NetError.io("WebSocket 送信 (error \(rc))") }
    }

    func receive() throws -> WebSocketMessage {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var read: DWORD = 0
            var type = WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE
            let rc = chunk.withUnsafeMutableBytes {
                WinHttpWebSocketReceive(socket, $0.baseAddress, DWORD($0.count), &read, &type)
            }
            if rc != 0 { throw NetError.closed }
            if type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE { throw NetError.closed }
            out += chunk[0 ..< Int(read)]
            guard out.count <= WebSocketClient.maxMessageSize else {
                throw WebSocketError.protocolViolation("メッセージが大きすぎます")
            }
            if type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE { return .binary(out) }
            if type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE { return .text(String(decoding: out, as: UTF8.self)) }
            // *_FRAGMENT_BUFFER_TYPE: 続きを読む
        }
    }

    func close() {
        closeLock.lock(); defer { closeLock.unlock() }
        if closed { return }
        closed = true
        // close フレームを送り (相手の応答は待たない)、ハンドルを閉じて受信待ちも解除する
        _ = WinHttpWebSocketShutdown(socket, 1000, nil, 0)
        WinHttpCloseHandle(socket)
    }
}
#endif

/// ファジング用の入口 (RDFuzz から使う)
public enum PlainWebSocketFuzz {
    public static func read(_ data: [UInt8], _ offset: inout Int) throws -> WebSocketMessage {
        var off = offset
        defer { offset = off }
        return try PlainWebSocket.readMessage(next: { n in
            guard n >= 0, data.count - off >= n else { throw NetError.closed }
            defer { off += n }
            return Array(data[off ..< off + n])
        }, control: { _, _ in })
    }
}
