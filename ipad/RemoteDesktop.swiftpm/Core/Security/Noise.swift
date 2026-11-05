// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/Security/Noise.swift からコピー。直接編集しないでください。
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// Noise Protocol Framework (rev 34) の Noise_XX_25519_ChaChaPoly_SHA256 実装。
// https://noiseprotocol.org/noise.html
//
//   XX:
//     -> e
//     <- e, ee, s, es
//     -> s, se
//
// 双方が長期鍵 (s) を持ち、ハンドシェイク後に互いの公開鍵を知る (相互認証)。
// 長期鍵は暗号化された状態で送られるので、盗聴者には誰が接続したか分からない。
// イニシエータ = ビューア、レスポンダ = ホスト。

public enum NoiseError: Error, CustomStringConvertible {
    case malformed(String)
    case decryptFailed
    case nonceExhausted
    case invalidState

    public var description: String {
        switch self {
        case .malformed(let s): return "ハンドシェイクのデータが不正です: \(s)"
        case .decryptFailed: return "復号に失敗しました (改ざん、または鍵の不一致)"
        case .nonceExhausted: return "nonce を使い切りました"
        case .invalidState: return "ハンドシェイクの状態が不正です"
        }
    }
}

let noiseDHLen = 32
let noiseHashLen = 32
let noiseTagLen = 16
/// Noise のメッセージ最大長
public let noiseMaxMessage = 65535

// MARK: - CipherState

struct NoiseCipherState {
    private(set) var key: SymmetricKey?
    private(set) var nonce: UInt64 = 0

    init(key: SymmetricKey? = nil) { self.key = key }

    var hasKey: Bool { key != nil }

    private static func nonceBytes(_ n: UInt64) -> [UInt8] {
        // 32bit の 0 + 64bit リトルエンディアンのカウンタ
        var b = [UInt8](repeating: 0, count: 12)
        for i in 0 ..< 8 { b[4 + i] = UInt8(truncatingIfNeeded: n >> (8 * UInt64(i))) }
        return b
    }

    mutating func encrypt(ad: [UInt8], _ plaintext: [UInt8]) throws -> [UInt8] {
        guard let k = key else { return plaintext }
        // 2^64-1 は予約値。nonce の再利用は絶対に起こさない。
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: k,
                                      nonce: try ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)),
                                      authenticating: ad)
        nonce += 1
        var out = [UInt8](box.ciphertext)
        out.append(contentsOf: box.tag)
        return out
    }

    mutating func decrypt(ad: [UInt8], _ ciphertext: [UInt8]) throws -> [UInt8] {
        guard let k = key else { return ciphertext }
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        guard ciphertext.count >= noiseTagLen else { throw NoiseError.decryptFailed }
        let split = ciphertext.count - noiseTagLen
        do {
            let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)),
                                               ciphertext: ciphertext[..<split],
                                               tag: ciphertext[split...])
            let pt = try ChaChaPoly.open(box, using: k, authenticating: ad)
            nonce += 1 // 成功したときだけ進める
            return [UInt8](pt)
        } catch {
            throw NoiseError.decryptFailed
        }
    }
}

// MARK: - SymmetricState

func noiseHMAC(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
    Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

/// Noise 仕様の HKDF (2 出力)
func noiseHKDF2(chainingKey: [UInt8], _ ikm: [UInt8]) -> ([UInt8], [UInt8]) {
    let temp = noiseHMAC(key: chainingKey, ikm)
    let o1 = noiseHMAC(key: temp, [0x01])
    let o2 = noiseHMAC(key: temp, o1 + [0x02])
    return (o1, o2)
}

struct NoiseSymmetricState {
    private(set) var ck: [UInt8]
    private(set) var h: [UInt8]
    var cipher = NoiseCipherState()

    init(protocolName: String) {
        let name = Array(protocolName.utf8)
        if name.count <= noiseHashLen {
            h = name + [UInt8](repeating: 0, count: noiseHashLen - name.count)
        } else {
            h = Array(SHA256.hash(data: name))
        }
        ck = h
    }

    mutating func mixKey(_ ikm: [UInt8]) {
        let (newCK, tempK) = noiseHKDF2(chainingKey: ck, ikm)
        ck = newCK
        cipher = NoiseCipherState(key: SymmetricKey(data: tempK))
    }

    mutating func mixHash(_ data: [UInt8]) {
        var hasher = SHA256()
        hasher.update(data: h)
        hasher.update(data: data)
        h = Array(hasher.finalize())
    }

    mutating func encryptAndHash(_ pt: [UInt8]) throws -> [UInt8] {
        let ct = try cipher.encrypt(ad: h, pt)
        mixHash(ct)
        return ct
    }

    mutating func decryptAndHash(_ ct: [UInt8]) throws -> [UInt8] {
        let pt = try cipher.decrypt(ad: h, ct)
        mixHash(ct)
        return pt
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (k1, k2) = noiseHKDF2(chainingKey: ck, [])
        return (NoiseCipherState(key: SymmetricKey(data: k1)), NoiseCipherState(key: SymmetricKey(data: k2)))
    }
}

// MARK: - HandshakeState (XX)

public final class NoiseXXHandshake {
    public static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"

    public enum Role { case initiator, responder }

    let role: Role
    private var ss: NoiseSymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey
    private var e: Curve25519.KeyAgreement.PrivateKey?
    private var re: Curve25519.KeyAgreement.PublicKey?
    private(set) var rs: Curve25519.KeyAgreement.PublicKey?
    private var step = 0

    /// 相手の長期公開鍵 (ハンドシェイク完了後に確定)
    public var remoteStaticKey: [UInt8]? { rs.map { Array($0.rawRepresentation) } }

    /// テスト用に一時鍵を固定できる
    private let ephemeralOverride: Curve25519.KeyAgreement.PrivateKey?

    public init(role: Role, staticKey: Curve25519.KeyAgreement.PrivateKey, prologue: [UInt8],
                ephemeralForTesting: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.role = role
        self.s = staticKey
        self.ephemeralOverride = ephemeralForTesting
        ss = NoiseSymmetricState(protocolName: Self.protocolName)
        ss.mixHash(prologue)
    }

    private func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pub: Curve25519.KeyAgreement.PublicKey) throws -> [UInt8] {
        // swift-crypto は小位数点などで結果が全ゼロになる場合に失敗する
        let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
        let bytes = secret.withUnsafeBytes { Array($0) }
        guard bytes.contains(where: { $0 != 0 }) else { throw NoiseError.malformed("DH の結果が不正") }
        return bytes
    }

    private func readPublic(_ msg: [UInt8], _ offset: inout Int) throws -> [UInt8] {
        guard msg.count - offset >= noiseDHLen else { throw NoiseError.malformed("長さ不足") }
        defer { offset += noiseDHLen }
        return Array(msg[offset ..< offset + noiseDHLen])
    }

    private func readEncrypted(_ msg: [UInt8], _ offset: inout Int, plainLen: Int) throws -> [UInt8] {
        let len = plainLen + (ss.cipher.hasKey ? noiseTagLen : 0)
        guard msg.count - offset >= len else { throw NoiseError.malformed("長さ不足") }
        defer { offset += len }
        return try ss.decryptAndHash(Array(msg[offset ..< offset + len]))
    }

    /// 次に送るハンドシェイクメッセージを作る
    public func writeMessage(payload: [UInt8] = []) throws -> [UInt8] {
        var out: [UInt8] = []
        switch (role, step) {
        case (.initiator, 0): // -> e
            let ek = ephemeralOverride ?? Curve25519.KeyAgreement.PrivateKey()
            e = ek
            let pub = Array(ek.publicKey.rawRepresentation)
            out += pub
            ss.mixHash(pub)
        case (.responder, 1): // <- e, ee, s, es
            guard let re = re else { throw NoiseError.invalidState }
            let ek = ephemeralOverride ?? Curve25519.KeyAgreement.PrivateKey()
            e = ek
            let pub = Array(ek.publicKey.rawRepresentation)
            out += pub
            ss.mixHash(pub)
            ss.mixKey(try dh(ek, re))
            out += try ss.encryptAndHash(Array(s.publicKey.rawRepresentation))
            ss.mixKey(try dh(s, re))
        case (.initiator, 2): // -> s, se
            guard let re = re else { throw NoiseError.invalidState }
            out += try ss.encryptAndHash(Array(s.publicKey.rawRepresentation))
            ss.mixKey(try dh(s, re))
        default:
            throw NoiseError.invalidState
        }
        out += try ss.encryptAndHash(payload)
        guard out.count <= noiseMaxMessage else { throw NoiseError.malformed("メッセージが長すぎます") }
        step += 1
        return out
    }

    /// 相手のハンドシェイクメッセージを処理して payload を返す
    public func readMessage(_ msg: [UInt8]) throws -> [UInt8] {
        guard msg.count <= noiseMaxMessage else { throw NoiseError.malformed("メッセージが長すぎます") }
        var off = 0
        switch (role, step) {
        case (.responder, 0): // -> e
            let pub = try readPublic(msg, &off)
            re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
            ss.mixHash(pub)
        case (.initiator, 1): // <- e, ee, s, es
            guard let e = e else { throw NoiseError.invalidState }
            let pub = try readPublic(msg, &off)
            let rek = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
            re = rek
            ss.mixHash(pub)
            ss.mixKey(try dh(e, rek))
            let rsBytes = try readEncrypted(msg, &off, plainLen: noiseDHLen)
            let rsk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rsBytes)
            rs = rsk
            ss.mixKey(try dh(e, rsk))
        case (.responder, 2): // -> s, se
            guard let e = e else { throw NoiseError.invalidState }
            let rsBytes = try readEncrypted(msg, &off, plainLen: noiseDHLen)
            let rsk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rsBytes)
            rs = rsk
            ss.mixKey(try dh(e, rsk))
        default:
            throw NoiseError.invalidState
        }
        let payload = try ss.decryptAndHash(Array(msg[off...]))
        step += 1
        return payload
    }

    public var isComplete: Bool { step == 3 }

    /// ハンドシェイクハッシュ (チャネルバインディングに使う)
    public var handshakeHash: [UInt8] { ss.h }

    /// 完了後に送信用・受信用の CipherState を取り出す
    func split() throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard isComplete else { throw NoiseError.invalidState }
        let (c1, c2) = ss.split()
        return role == .initiator ? (c1, c2) : (c2, c1)
    }
}
