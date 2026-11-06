#if canImport(Network)
import Foundation
import Network

/// Network.framework の NWConnection を通信路として使う (iPad / Mac のビューア側)。
/// Bonjour で見つけた PC へ名前でつなぐときと、iPad から IP アドレスでつなぐときに使う。
/// 中身は SecureStream (Noise) の暗号文なので、通信路そのものは信用しない前提は BSD ソケットと同じ。
public final class NWTransport: Transport {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "rd.nwtransport")
    private let label: String
    private var receiveTimeout: Double = 0

    public var peerDescription: String { label }
    public var peerIP: String {
        if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint { return "\(host)" }
        return ""
    }
    /// ビューア側では使わない (端末登録を LAN に限る判定はホスト側の TCP 接続で行う)
    public var isLocalNetwork: Bool { false }

    private init(conn: NWConnection, label: String) {
        self.conn = conn
        self.label = label
    }

    /// Bonjour で見つけたサービス名で接続する
    public static func connect(bonjourName name: String, timeout: Double = 15) throws -> NWTransport {
        try connect(to: .service(name: name, type: rdBonjourServiceTypeName, domain: "local.", interface: nil),
                    label: name, timeout: timeout)
    }

    /// ホスト名 / IP アドレスとポートで接続する
    public static func connect(host: String, port: UInt16, timeout: Double = 15) throws -> NWTransport {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw NetError.connect("\(host):\(port)") }
        return try connect(to: .hostPort(host: NWEndpoint.Host(host), port: p), label: "\(host):\(port)",
                           timeout: timeout)
    }

    public static func connect(to endpoint: NWEndpoint, label: String, timeout: Double) throws -> NWTransport {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let t = NWTransport(conn: NWConnection(to: endpoint, using: params), label: label)
        try t.start(timeout: timeout)
        return t
    }

    /// コールバック (別スレッド) と待つ側で共有する状態
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func with<R>(_ f: (inout T) -> R) -> R {
            lock.lock(); defer { lock.unlock() }
            return f(&value)
        }
    }

    private struct ConnectState {
        var ready = false
        var failure: NWError?
        var waiting: NWError?
        var waitingSince: Date?
        var cancelled = false
    }

    private func start(timeout: Double) throws {
        let st = Box(ConnectState())
        conn.stateUpdateHandler = { state in
            st.with { s in
                switch state {
                case .ready: s.ready = true
                case let .failed(e): s.failure = e
                case let .waiting(e):
                    // 拒否・経路なしなど。Network.framework は再試行し続けるので、少し待って諦める
                    s.waiting = e
                    if s.waitingSince == nil { s.waitingSince = Date() }
                case .cancelled: s.cancelled = true
                default: break
                }
            }
        }
        conn.start(queue: queue)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let s = st.with { $0 }
            if s.ready { return }
            if let f = s.failure {
                conn.cancel()
                throw NetError.connect("\(label) (\(Self.describe(f)))")
            }
            if s.cancelled { throw NetError.connect("\(label) (中断されました)") }
            if let w = s.waiting, let since = s.waitingSince, Date().timeIntervalSince(since) > 4 {
                conn.cancel()
                throw NetError.connect("\(label) (\(Self.describe(w)))")
            }
            if Date() > deadline {
                conn.cancel()
                let why = s.waiting.map(Self.describe) ?? "応答がありません。PC の電源と、同じ Wi-Fi につながっているか確認してください"
                throw NetError.connect("\(label) (\(why))")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// エラーを、番号と利用者向けの原因・対処にする
    static func describe(_ e: NWError) -> String {
        switch e {
        case let .posix(code):
            return "error \(code.rawValue)\(Net.connectHint(code.rawValue))"
        case let .dns(code):
            return "名前が見つかりません (DNS \(code))。PC で RDHost が起動しているか、同じ Wi-Fi か確認してください"
        default:
            return "\(e)"
        }
    }

    public func setReceiveTimeout(_ seconds: Double) {
        receiveTimeout = seconds
    }

    public func sendAll(_ bytes: [UInt8]) throws {
        let done = DispatchSemaphore(value: 0)
        let err = Box<NWError?>(nil)
        conn.send(content: Data(bytes), completion: .contentProcessed { e in
            err.with { $0 = e }
            done.signal()
        })
        if done.wait(timeout: .now() + 30) == .timedOut {
            conn.cancel()
            throw NetError.io("send (タイムアウト)")
        }
        if let e = err.with({ $0 }) { throw NetError.io("send (\(e))") }
    }

    private struct Received {
        var data: Data?
        var error: NWError?
        var complete = false
    }

    public func receive(exactly n: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(n)
        while out.count < n {
            let done = DispatchSemaphore(value: 0)
            let got = Box(Received())
            let want = n - out.count
            conn.receive(minimumIncompleteLength: want, maximumLength: want) { data, _, isComplete, error in
                got.with { $0 = Received(data: data, error: error, complete: isComplete) }
                done.signal()
            }
            if receiveTimeout > 0 {
                if done.wait(timeout: .now() + receiveTimeout) == .timedOut {
                    conn.cancel()
                    throw NetError.io("recv (タイムアウト)")
                }
            } else {
                done.wait()
            }
            let r = got.with { $0 }
            if let d = r.data, !d.isEmpty {
                out.append(contentsOf: d)
            } else if let e = r.error {
                throw NetError.io("recv (\(e))")
            } else if r.complete {
                throw NetError.closed
            }
        }
        return out
    }

    public func close() {
        conn.cancel()
    }
}

/// 同じ Wi-Fi で RDHost を探す (Bonjour)
public final class HostBrowser {
    private var browser: NWBrowser?
    /// 見つかった PC の名前 (メインスレッドで呼ばれる)
    public var onChange: (([String]) -> Void)?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: rdBonjourServiceTypeName, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var names = Set<String>()
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint { names.insert(name) }
            }
            let sorted = names.sorted()
            DispatchQueue.main.async { self?.onChange?(sorted) }
        }
        b.start(queue: .main)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
#endif
