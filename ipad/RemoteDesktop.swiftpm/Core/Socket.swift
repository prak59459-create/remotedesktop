// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/Socket.swift からコピー。直接編集しないでください。
import Foundation

#if os(Windows)
import WinSDK
public typealias NativeSocket = SOCKET
private let invalidSocket: SOCKET = ~SOCKET(0)
#elseif canImport(Glibc)
import Glibc
public typealias NativeSocket = Int32
private let invalidSocket: Int32 = -1
#elseif canImport(Darwin)
import Darwin
public typealias NativeSocket = Int32
private let invalidSocket: Int32 = -1
#endif

// 以下の定数は Windows / Linux / macOS で同じ値。
private let kAF_UNSPEC: Int32 = 0
private let kAF_INET: Int32 = 2
private let kSOCK_STREAM: Int32 = 1
private let kIPPROTO_TCP: Int32 = 6
private let kTCP_NODELAY: Int32 = 1
private let kAI_PASSIVE: Int32 = 1

public enum NetError: Error, CustomStringConvertible {
    case resolve(String)
    case connect(String)
    case listen(String)
    case closed
    case io(String)

    public var description: String {
        switch self {
        case .resolve(let s): return "アドレス解決に失敗: \(s)"
        case .connect(let s): return "接続に失敗: \(s)"
        case .listen(let s): return "待ち受けに失敗: \(s)"
        case .closed: return "接続が閉じられました"
        case .io(let s): return "通信エラー: \(s)"
        }
    }
}

// MARK: - プラットフォーム差分を吸収する薄いラッパー

private func lastErrorCode() -> Int32 {
    #if os(Windows)
    return WSAGetLastError()
    #else
    return errno
    #endif
}

private func rawClose(_ s: NativeSocket) {
    #if os(Windows)
    _ = closesocket(s)
    #else
    _ = close(s)
    #endif
}

private func rawShutdown(_ s: NativeSocket) {
    #if os(Windows)
    _ = shutdown(s, 2) // SD_BOTH
    #else
    _ = shutdown(s, Int32(SHUT_RDWR))
    #endif
}

private func rawSend(_ s: NativeSocket, _ p: UnsafeRawPointer, _ n: Int) -> Int {
    #if os(Windows)
    return Int(send(s, p.assumingMemoryBound(to: CChar.self), Int32(min(n, Int(Int32.max))), 0))
    #elseif canImport(Glibc)
    return send(s, p, n, Int32(MSG_NOSIGNAL))
    #else
    return send(s, p, n, 0)
    #endif
}

private func rawRecv(_ s: NativeSocket, _ p: UnsafeMutableRawPointer, _ n: Int) -> Int {
    #if os(Windows)
    return Int(recv(s, p.assumingMemoryBound(to: CChar.self), Int32(min(n, Int(Int32.max))), 0))
    #else
    return recv(s, p, n, 0)
    #endif
}

private func setOpt(_ s: NativeSocket, _ level: Int32, _ name: Int32, _ value: Int32) {
    var v = value
    #if os(Windows)
    _ = withUnsafePointer(to: &v) {
        $0.withMemoryRebound(to: CChar.self, capacity: 4) {
            setsockopt(s, level, name, $0, Int32(MemoryLayout<Int32>.size))
        }
    }
    #else
    _ = setsockopt(s, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

public enum Net {
    private static let once: Void = {
        #if os(Windows)
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
        #else
        // 切断済みソケットへの書き込みでプロセスが落ちないようにする
        signal(SIGPIPE, SIG_IGN)
        #endif
    }()

    /// ソケットを使う前に一度呼ぶ (Windows では WSAStartup)。
    public static func initialize() { _ = once }

    /// 外へ出るときに使われる自分の IPv4 アドレス (家の LAN の IP)。UDP の宛先を決めるだけでパケットは送らない。
    public static func primaryLocalIPv4() -> String? {
        initialize()
        var hints = addrinfo()
        hints.ai_family = kAF_INET
        hints.ai_socktype = 2 // SOCK_DGRAM
        hints.ai_flags = 4 // AI_NUMERICHOST
        var result: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo("8.8.8.8", "53", &hints, &result) == 0, let ai = result else { return nil }
        defer { freeaddrinfo(ai) }
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s != invalidSocket else { return nil }
        defer { rawClose(s) }
        guard connect(s, ai.pointee.ai_addr, numericCast(ai.pointee.ai_addrlen)) == 0 else { return nil }
        var addr = sockaddr_in()
        #if os(Windows)
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        guard ok == 0 else { return nil }
        let ip = describeIP(addr)
        return ip == "0.0.0.0" ? nil : ip
    }

    /// 接続エラーの番号から、利用者向けの原因と対処を返す (該当なしなら空)
    public static func connectHint(_ code: Int32) -> String {
        #if os(Windows)
        let refused: [Int32] = [10061], unreachable: [Int32] = [10065, 10051], timedOut: [Int32] = [10060]
        #else
        let refused = [ECONNREFUSED], unreachable = [EHOSTUNREACH, ENETUNREACH], timedOut = [ETIMEDOUT]
        #endif
        if refused.contains(code) {
            return "。PC には届きましたが、RDHost がそのポートで待ち受けていません (RDHost が起動しているか、ポート番号が合っているか確認してください)"
        }
        if unreachable.contains(code) {
            return "。PC まで届いていません。i-フィルターなどのフィルターアプリや VPN が通信を止めていないか、ローカルネットワークの許可、IP アドレスを確認してください"
        }
        if timedOut.contains(code) {
            return "。応答がありません。PC の電源、同じ Wi-Fi か、Windows ファイアウォールを確認してください"
        }
        return ""
    }
}

// MARK: - TCP 接続

/// 双方向のバイトストリーム (平文 TCP / 暗号化チャネル共通)
public protocol ByteStream: AnyObject {
    func sendAll(_ bytes: [UInt8]) throws
    func receive(exactly n: Int) throws -> [UInt8]
    func close()
}

public final class TCPConnection: ByteStream {
    private let fd: NativeSocket
    private let closeLock = NSLock()
    private var isClosed = false
    public let peerDescription: String
    /// 相手の IP アドレス (ポートなし)。レート制限のキーに使う。
    public let peerIP: String

    init(fd: NativeSocket, peer: String, peerIP: String? = nil) {
        self.fd = fd
        self.peerDescription = peer
        self.peerIP = peerIP ?? peer
        setOpt(fd, kIPPROTO_TCP, kTCP_NODELAY, 1)
    }

    // ファイルディスクリプタの解放は、このオブジェクトを誰も参照しなくなったときだけ行う。
    // close() 直後に解放すると、別スレッドが送受信中の番号を OS が新しい接続に再利用し、
    // 古いセッションのデータが新しい接続に書き込まれてしまう (use-after-close)。
    deinit {
        close()
        rawClose(fd)
    }

    private var closedFlag: Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        return isClosed
    }

    /// host:port へ接続する。
    public static func open(host: String, port: UInt16) throws -> TCPConnection {
        Net.initialize()
        var hints = addrinfo()
        hints.ai_family = kAF_UNSPEC
        hints.ai_socktype = kSOCK_STREAM
        hints.ai_protocol = kIPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            throw NetError.resolve("\(host):\(port) (code \(rc))")
        }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var lastErr: Int32 = 0
        while let ai = cursor {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s != invalidSocket {
                if connect(s, ai.pointee.ai_addr, numericCast(ai.pointee.ai_addrlen)) == 0 {
                    return TCPConnection(fd: s, peer: "\(host):\(port)")
                }
                lastErr = lastErrorCode()
                rawClose(s)
            } else {
                lastErr = lastErrorCode()
            }
            cursor = ai.pointee.ai_next
        }
        throw NetError.connect("\(host):\(port) (error \(lastErr))\(Net.connectHint(lastErr))")
    }

    public func sendAll(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try sendAll($0) }
    }

    public func sendAll(_ buf: UnsafeRawBufferPointer) throws {
        guard let base = buf.baseAddress else { return }
        guard !closedFlag else { throw NetError.closed }
        var off = 0
        while off < buf.count {
            let n = rawSend(fd, base + off, buf.count - off)
            if n <= 0 { throw NetError.io("send (error \(lastErrorCode()))") }
            off += n
        }
    }

    /// ちょうど n バイト読む。相手が切断したら NetError.closed。
    public func receive(exactly n: Int) throws -> [UInt8] {
        guard !closedFlag else { throw NetError.closed }
        var out = [UInt8](repeating: 0, count: n)
        var off = 0
        try out.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            while off < n {
                let r = rawRecv(fd, base + off, n - off)
                if r == 0 { throw NetError.closed }
                if r < 0 { throw NetError.io("recv (error \(lastErrorCode()))") }
                off += r
            }
        }
        return out
    }

    /// 受信タイムアウト (秒)。0 で無効。認証前の接続を長く占有させないために使う。
    public func setReceiveTimeout(_ seconds: Double) {
        #if os(Windows)
        var ms = DWORD(max(0, seconds) * 1000)
        _ = withUnsafePointer(to: &ms) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) {
                setsockopt(fd, 0xFFFF /* SOL_SOCKET */, 0x1006 /* SO_RCVTIMEO */, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
        #else
        var tv = timeval()
        tv.tv_sec = Int(seconds)
        tv.tv_usec = numericCast(Int((seconds - Double(Int(seconds))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        if isClosed { return }
        isClosed = true
        // 通信を止めて、ブロック中の送受信を起こす (番号の解放は deinit で)
        rawShutdown(fd)
    }
}

// MARK: - TCP 待ち受け

public final class TCPListener {
    private let fd: NativeSocket
    public let port: UInt16
    private let closeLock = NSLock()
    private var closed = false

    /// bindAddress:port で待ち受ける (IPv4)。bindAddress が nil なら全インターフェース。
    public init(port: UInt16, bindAddress: String? = nil) throws {
        Net.initialize()
        self.port = port
        var hints = addrinfo()
        hints.ai_family = kAF_INET
        hints.ai_socktype = kSOCK_STREAM
        hints.ai_protocol = kIPPROTO_TCP
        hints.ai_flags = kAI_PASSIVE
        var result: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(bindAddress, String(port), &hints, &result)
        guard rc == 0, let ai = result else { throw NetError.resolve("port \(port) (code \(rc))") }
        defer { freeaddrinfo(ai) }

        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s != invalidSocket else { throw NetError.listen("socket (error \(lastErrorCode()))") }
        #if !os(Windows)
        setOpt(s, SOL_SOCKET, SO_REUSEADDR, 1)
        #endif
        guard bind(s, ai.pointee.ai_addr, numericCast(ai.pointee.ai_addrlen)) == 0 else {
            let e = lastErrorCode()
            rawClose(s)
            throw NetError.listen("bind port \(port) (error \(e))")
        }
        guard listen(s, 8) == 0 else {
            let e = lastErrorCode()
            rawClose(s)
            throw NetError.listen("listen (error \(e))")
        }
        fd = s
    }

    deinit {
        closeLock.lock()
        let wasClosed = closed
        closeLock.unlock()
        if !wasClosed { rawClose(fd) }
    }

    /// 待ち受けをやめる。accept() で待っているスレッドはエラーで戻る (戻ったあとは accept を呼ばないこと)
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        if closed { return }
        closed = true
        rawShutdown(fd)
        rawClose(fd) // Windows は closesocket でないと accept が戻らない。ポートもすぐ空く
    }

    public var isClosed: Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        return closed
    }

    /// 実際に待ち受けているポート (port 0 で OS に選ばせたとき用)
    public var boundPort: UInt16 {
        var addr = sockaddr_in()
        #if os(Windows)
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return ok == 0 ? UInt16(bigEndian: addr.sin_port) : port
    }

    public func accept() throws -> TCPConnection {
        #if os(Windows)
        var addr = sockaddr_in()
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        let c = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                acceptConnection(fd, $0, &len)
            }
        }
        guard c != invalidSocket else { throw NetError.io("accept (error \(lastErrorCode()))") }
        return TCPConnection(fd: c, peer: describe(addr), peerIP: describeIP(addr))
    }
}

#if os(Windows)
private func acceptConnection(_ s: NativeSocket, _ a: UnsafeMutablePointer<sockaddr>, _ l: UnsafeMutablePointer<Int32>) -> NativeSocket {
    accept(s, a, l)
}
#else
private func acceptConnection(_ s: NativeSocket, _ a: UnsafeMutablePointer<sockaddr>, _ l: UnsafeMutablePointer<socklen_t>) -> NativeSocket {
    accept(s, a, l)
}
#endif

private func describeIP(_ addr: sockaddr_in) -> String {
    // sin_addr はネットワークバイトオーダー
    let b = withUnsafeBytes(of: addr.sin_addr) { Array($0.prefix(4)) }
    return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
}

private func describe(_ addr: sockaddr_in) -> String {
    "\(describeIP(addr)):\(UInt16(bigEndian: addr.sin_port))"
}
