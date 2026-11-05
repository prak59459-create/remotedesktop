#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// プロトコルのバージョンを Noise の prologue に入れる。
/// バージョンや用途が違う相手とはハンドシェイク自体が成立しない (ダウングレード防止)。
public let rdPrologue = Array("RemoteDesktop/3 Noise_XX".utf8)

public enum SecureStreamError: Error, CustomStringConvertible {
    case postQuantumRequired

    public var description: String {
        switch self {
        case .postQuantumRequired:
            return "ホストが耐量子暗号 (ML-KEM) を必須にしていますが、この端末の OS では使えません"
        }
    }
}

/// Noise でハンドシェイクした暗号化ストリーム。
/// 通信路上の 1 レコード = [長さ u16 BE][暗号文 (平文 + 16 バイトの認証タグ)]
///
/// ハンドシェイク直後に、暗号化された最初のレコードで耐量子鍵交換 (ML-KEM-768) を交渉する。
/// 両端が対応していれば、以降の鍵は X25519 と ML-KEM の両方から作り直す (PostQuantum.swift)。
/// さらに一定数のレコードごとに鍵を更新し、長いセッションでも古い鍵で多くを守らない。
public final class SecureStream: ByteStream {
    /// 相手の長期公開鍵 (X25519, 32 バイト)。ハンドシェイクで相手が秘密鍵を持つことが証明済み。
    public let remoteStaticKey: [UInt8]
    /// ハンドシェイクハッシュ。この接続固有の値で、ペアリング証明のチャネルバインディングに使う。
    public let handshakeHash: [UInt8]
    public let transport: Transport
    /// 耐量子のハイブリッド鍵交換を使っているか
    public private(set) var isPostQuantum = false

    /// このレコード数ごとに鍵を更新する (1 レコード最大 64KB なので約 650MB ごと)
    public static var rekeyInterval: UInt64 = 10_000

    private var sendCipher: NoiseCipherState
    private var recvCipher: NoiseCipherState
    private let sendLock = NSLock()
    private var buffer: [UInt8] = []
    private var bufferOffset = 0

    static let maxPlaintextPerRecord = noiseMaxMessage - noiseTagLen
    private static let negotiationVersion: UInt8 = 3
    private static let flagPQ: UInt8 = 0x01
    private static let flagRejected: UInt8 = 0x80

    private init(transport: Transport, handshake: NoiseXXHandshake) throws {
        guard let rs = handshake.remoteStaticKey else { throw NoiseError.invalidState }
        self.transport = transport
        remoteStaticKey = rs
        handshakeHash = handshake.handshakeHash
        let (s, r) = try handshake.split()
        sendCipher = s
        recvCipher = r
    }

    /// ビューア側 (イニシエータ)
    public static func connect(_ tcp: Transport, identity: StaticIdentity,
                               offerPostQuantum: Bool = PostQuantum.isAvailable) throws -> SecureStream {
        let hs = NoiseXXHandshake(role: .initiator, staticKey: identity.privateKey, prologue: rdPrologue)
        try writeFrame(tcp, try hs.writeMessage())
        _ = try hs.readMessage(try readFrame(tcp))
        try writeFrame(tcp, try hs.writeMessage())
        let s = try SecureStream(transport: tcp, handshake: hs)

        // 耐量子鍵交換の交渉 (ここから先は暗号化済み)
        let pq = offerPostQuantum ? try PostQuantum.Initiator() : nil
        var offer: [UInt8] = [negotiationVersion, pq == nil ? 0 : flagPQ]
        if let pq = pq { offer += pq.publicKey }
        try s.sendRecord(offer)
        let reply = try s.receiveRecord()
        guard reply.count >= 2, reply[0] == negotiationVersion else { throw NoiseError.malformed("交渉の応答") }
        if reply[1] & flagRejected != 0 { throw SecureStreamError.postQuantumRequired }
        if reply[1] & flagPQ != 0 {
            guard let pq = pq, reply.count == 2 + PostQuantum.ciphertextSize else {
                throw NoiseError.malformed("ML-KEM の応答")
            }
            let ct = Array(reply[2...])
            try s.mixPostQuantum(secret: try pq.decapsulate(ct), publicKey: pq.publicKey, ciphertext: ct, initiator: true)
        }
        s.enableRekey()
        return s
    }

    /// ホスト側 (レスポンダ)
    public static func accept(_ tcp: Transport, identity: StaticIdentity,
                              requirePostQuantum: Bool = false) throws -> SecureStream {
        let hs = NoiseXXHandshake(role: .responder, staticKey: identity.privateKey, prologue: rdPrologue)
        _ = try hs.readMessage(try readFrame(tcp))
        try writeFrame(tcp, try hs.writeMessage())
        _ = try hs.readMessage(try readFrame(tcp))
        let s = try SecureStream(transport: tcp, handshake: hs)

        let offer = try s.receiveRecord()
        guard offer.count >= 2, offer[0] == negotiationVersion else { throw NoiseError.malformed("交渉の要求") }
        let wantsPQ = offer[1] & flagPQ != 0
        if wantsPQ {
            guard offer.count == 2 + PostQuantum.publicKeySize else { throw NoiseError.malformed("ML-KEM 公開鍵") }
            let ek = Array(offer[2...])
            let (ct, secret) = try PostQuantum.encapsulate(to: ek)
            try s.sendRecord([negotiationVersion, flagPQ] + ct)
            try s.mixPostQuantum(secret: secret, publicKey: ek, ciphertext: ct, initiator: false)
        } else if requirePostQuantum {
            try? s.sendRecord([negotiationVersion, flagRejected])
            s.close()
            throw SecureStreamError.postQuantumRequired
        } else {
            try s.sendRecord([negotiationVersion, 0])
        }
        s.enableRekey()
        return s
    }

    /// X25519 由来の鍵と ML-KEM の共有秘密から、新しい送受信鍵を作る
    private func mixPostQuantum(secret: [UInt8], publicKey: [UInt8], ciphertext: [UInt8], initiator: Bool) throws {
        var h = SHA256()
        h.update(data: Array("RemoteDesktop PQ hybrid v1".utf8))
        h.update(data: handshakeHash)
        h.update(data: publicKey)
        h.update(data: ciphertext)
        let ck = Array(h.finalize())
        let (k1, k2) = noiseHKDF2(chainingKey: ck, secret)
        let c1 = NoiseCipherState(key: SymmetricKey(data: k1)), c2 = NoiseCipherState(key: SymmetricKey(data: k2))
        sendCipher = initiator ? c1 : c2
        recvCipher = initiator ? c2 : c1
        isPostQuantum = true
    }

    private func enableRekey() {
        sendCipher.rekeyInterval = Self.rekeyInterval
        recvCipher.rekeyInterval = Self.rekeyInterval
    }

    var rekeyCounts: (send: Int, receive: Int) { (sendCipher.rekeyCount, recvCipher.rekeyCount) }

    private static func writeFrame(_ tcp: Transport, _ bytes: [UInt8]) throws {
        precondition(bytes.count <= noiseMaxMessage)
        var out = [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]
        out.append(contentsOf: bytes)
        try tcp.sendAll(out)
    }

    private static func readFrame(_ tcp: Transport) throws -> [UInt8] {
        let h = try tcp.receive(exactly: 2)
        let len = Int(h[0]) << 8 | Int(h[1])
        return len > 0 ? try tcp.receive(exactly: len) : []
    }

    /// 1 レコードをそのまま送る / 受ける (交渉用)
    private func sendRecord(_ plaintext: [UInt8]) throws {
        sendLock.lock(); defer { sendLock.unlock() }
        try Self.writeFrame(transport, try sendCipher.encrypt(ad: [], plaintext))
    }

    private func receiveRecord() throws -> [UInt8] {
        try recvCipher.decrypt(ad: [], try Self.readFrame(transport))
    }

    public func sendAll(_ bytes: [UInt8]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        var off = 0
        repeat {
            let n = min(Self.maxPlaintextPerRecord, bytes.count - off)
            let ct = try sendCipher.encrypt(ad: [], Array(bytes[off ..< off + n]))
            try Self.writeFrame(transport, ct)
            off += n
        } while off < bytes.count
    }

    /// 受信は 1 スレッドから呼ぶこと
    public func receive(exactly n: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(n)
        while out.count < n {
            if bufferOffset >= buffer.count {
                let frame = try Self.readFrame(transport)
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

    public func close() { transport.close() }
}
