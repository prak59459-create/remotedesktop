import Foundation
import RDCore

/// ホストに接続して画面を受信し、入力イベントを送るクライアント (UI 非依存)
final class ViewerClient {
    let endpoint: ViewerConnector.Endpoint
    let framebuffer = Framebuffer()

    /// 以下のコールバックは受信スレッドから呼ばれる
    var onHello: ((Int, Int) -> Void)?
    var onFrame: ((Framebuffer) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var channel: MessageChannel?
    private(set) var bytesReceived = 0
    private(set) var framesReceived = 0
    private(set) var session: ViewerConnector.Session?
    private let pairingCode: PairingCode?
    private let expectedHostKey: [UInt8]?

    var label: String {
        switch endpoint {
        case let .direct(host, port): return "\(host):\(port)"
        case let .bonjour(name): return name
        case let .relay(url): return "中継 \(url.host ?? "")"
        }
    }

    init(endpoint: ViewerConnector.Endpoint, expectedHostKey: [UInt8]? = nil, pairingCode: PairingCode? = nil) {
        self.endpoint = endpoint
        self.expectedHostKey = expectedHostKey
        self.pairingCode = pairingCode
    }

    convenience init(host: String, port: UInt16, pairingCode: PairingCode? = nil) {
        self.init(endpoint: .direct(host: host, port: port), pairingCode: pairingCode)
    }

    /// GUI では端末鍵を本人確認つきで取り出す (headless は自動テスト用なので使わない)
    var useDeviceKeyProtection = false
    private(set) var keyProtection = ""

    /// 接続・暗号化・相互認証 (ブロッキング) してから受信スレッドを起動する
    func connect() throws {
        let identity: StaticIdentity
        #if os(macOS)
        if useDeviceKeyProtection {
            let (id, level) = try DeviceKeyProtection.loadOrCreateIdentity(name: "viewer_identity_v2",
                                                                            reason: "Windows PC に接続します")
            identity = id
            keyProtection = level.rawValue
        } else {
            identity = try SecretStore.loadOrCreateIdentity(name: "viewer_identity")
        }
        #else
        identity = try SecretStore.loadOrCreateIdentity(name: "viewer_identity")
        #endif
        let known = try TrustStore(fileName: "trusted_hosts.json")
        let s = try ViewerConnector.connect(to: endpoint, identity: identity, knownHosts: known,
                                            expectedHostKey: expectedHostKey, pairingCode: pairingCode,
                                            deviceName: deviceName())
        session = s
        channel = s.channel
        Thread { [self] in receiveLoop() }.start()
    }

    func send(_ event: ClientEvent) {
        guard let ch = channel else { return }
        try? ch.send(event)
    }

    func disconnect() { channel?.close() }

    private func receiveLoop() {
        guard let ch = channel else { return }
        do {
            while true {
                let (type, payload) = try ch.receive()
                bytesReceived += payload.count + 5
                switch MessageType(rawValue: type) {
                case .hello:
                    let h = try Hello.decode(payload)
                    framebuffer.resize(width: h.width, height: h.height)
                    onHello?(h.width, h.height)
                case .frame:
                    try framebuffer.apply(payload)
                    framesReceived += 1
                    try ch.send(.frameAck)
                    onFrame?(framebuffer)
                default:
                    break
                }
            }
        } catch NetError.closed {
            ch.close()
            onClose?(nil)
        } catch {
            ch.close()
            onClose?(error)
        }
    }
}

func deviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
    return ProcessInfo.processInfo.hostName
    #endif
}
