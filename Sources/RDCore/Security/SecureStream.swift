import Crypto
import Foundation

/// プロトコルのバージョンを Noise の prologue に入れる。
/// バージョンや用途が違う相手とはハンドシェイク自体が成立しない (ダウングレード防止)。
public let rdPrologue = Array("RemoteDesktop/2 Noise_XX".utf8)

/// Noise でハンドシェイクした暗号化ストリーム。
/// 通信路上の 1 レコード = [長さ u16 BE][暗号文 (平文 + 16 バイトの認証タグ)]
public final class SecureStream: ByteStream {
    /// 相手の長期公開鍵 (X25519, 32 バイト)。ハンドシェイクで相手が秘密鍵を持つことが証明済み。
    public let remoteStaticKey: [UInt8]
    /// ハンドシェイクハッシュ。この接続固有の値で、ペアリング証明のチャネルバインディングに使う。
    public let handshakeHash: [UInt8]
    public let tcp: TCPConnection

    private var sendCipher: NoiseCipherState
    private var recvCipher: NoiseCipherState
    private let sendLock = NSLock()
    private var buffer: [UInt8] = []
    private var bufferOffset = 0

    static let maxPlaintextPerRecord = noiseMaxMessage - noiseTagLen

    private init(tcp: TCPConnection, handshake: NoiseXXHandshake) throws {
        guard let rs = handshake.remoteStaticKey else { throw NoiseError.invalidState }
        self.tcp = tcp
        remoteStaticKey = rs
        handshakeHash = handshake.handshakeHash
        let (s, r) = try handshake.split()
        sendCipher = s
        recvCipher = r
    }

    /// ビューア側 (イニシエータ)
    public static func connect(_ tcp: TCPConnection, identity: StaticIdentity) throws -> SecureStream {
        let hs = NoiseXXHandshake(role: .initiator, staticKey: identity.privateKey, prologue: rdPrologue)
        try writeFrame(tcp, try hs.writeMessage())
        _ = try hs.readMessage(try readFrame(tcp))
        try writeFrame(tcp, try hs.writeMessage())
        return try SecureStream(tcp: tcp, handshake: hs)
    }

    /// ホスト側 (レスポンダ)
    public static func accept(_ tcp: TCPConnection, identity: StaticIdentity) throws -> SecureStream {
        let hs = NoiseXXHandshake(role: .responder, staticKey: identity.privateKey, prologue: rdPrologue)
        _ = try hs.readMessage(try readFrame(tcp))
        try writeFrame(tcp, try hs.writeMessage())
        _ = try hs.readMessage(try readFrame(tcp))
        return try SecureStream(tcp: tcp, handshake: hs)
    }

    private static func writeFrame(_ tcp: TCPConnection, _ bytes: [UInt8]) throws {
        precondition(bytes.count <= noiseMaxMessage)
        var out = [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]
        out.append(contentsOf: bytes)
        try tcp.sendAll(out)
    }

    private static func readFrame(_ tcp: TCPConnection) throws -> [UInt8] {
        let h = try tcp.receive(exactly: 2)
        let len = Int(h[0]) << 8 | Int(h[1])
        return len > 0 ? try tcp.receive(exactly: len) : []
    }

    public func sendAll(_ bytes: [UInt8]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        var off = 0
        repeat {
            let n = min(Self.maxPlaintextPerRecord, bytes.count - off)
            let ct = try sendCipher.encrypt(ad: [], Array(bytes[off ..< off + n]))
            try Self.writeFrame(tcp, ct)
            off += n
        } while off < bytes.count
    }

    /// 受信は 1 スレッドから呼ぶこと
    public func receive(exactly n: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(n)
        while out.count < n {
            if bufferOffset >= buffer.count {
                let frame = try Self.readFrame(tcp)
                // 1 バイトでも改ざんされていれば例外 → 接続を切る
                buffer = try recvCipher.decrypt(ad: [], frame)
                bufferOffset = 0
                continue
            }
            let take = min(n - out.count, buffer.count - bufferOffset)
            out.append(contentsOf: buffer[bufferOffset ..< bufferOffset + take])
            bufferOffset += take
        }
        return out
    }

    public func close() { tcp.close() }
}
