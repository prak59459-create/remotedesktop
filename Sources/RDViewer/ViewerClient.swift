import Foundation
import RDCore

/// ホストに接続して画面を受信し、入力イベントを送るクライアント (UI 非依存)
final class ViewerClient {
    let host: String
    let port: UInt16
    let framebuffer = Framebuffer()

    /// 以下のコールバックは受信スレッドから呼ばれる
    var onHello: ((Int, Int) -> Void)?
    var onFrame: ((Framebuffer) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var channel: MessageChannel?
    private(set) var bytesReceived = 0
    private(set) var framesReceived = 0

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// 接続 (ブロッキング) してから受信スレッドを起動する
    func connect() throws {
        let conn = try TCPConnection.open(host: host, port: port)
        channel = MessageChannel(conn)
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
