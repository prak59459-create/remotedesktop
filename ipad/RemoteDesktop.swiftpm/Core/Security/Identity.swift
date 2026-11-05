// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/Security/Identity.swift からコピー。直接編集しないでください。
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// 端末の長期鍵 (X25519)。ホストもビューアも 1 つずつ持ち、これが「身元」になる。
public struct StaticIdentity {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
    }

    public static func generate() -> StaticIdentity {
        StaticIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    public init(rawPrivateKey: [UInt8]) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    public var rawPrivateKey: [UInt8] { Array(privateKey.rawRepresentation) }
    public var publicKey: [UInt8] { Array(privateKey.publicKey.rawRepresentation) }
    public var fingerprint: String { Fingerprint.display(publicKey) }
}

public enum Fingerprint {
    /// 公開鍵の SHA-256
    public static func digest(_ publicKey: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: publicKey))
    }

    /// 人が目で照合する用の表記 (SHA-256 の先頭 160bit を Base32 で 4 文字区切り)
    public static func display(_ publicKey: [UInt8]) -> String {
        Base32.grouped(Base32.encode(Array(digest(publicKey).prefix(20))))
    }

    /// 保存・比較用の 16 進表記 (公開鍵そのもの)
    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func fromHex(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexValue(chars[i]), let lo = hexValue(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30 ... 0x39: return c - 0x30
        case 0x61 ... 0x66: return c - 0x61 + 10
        case 0x41 ... 0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

/// Crockford Base32 (紛らわしい I, L, O, U を使わない)
public enum Base32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    public static func encode(_ data: [UInt8]) -> String {
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for b in data {
            buffer = buffer << 8 | UInt32(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 0x1F)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// 区切り文字・空白を無視し、O→0、I/L→1 として読む
    public static func decode(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for ch in s.uppercased().utf8 {
            var c = ch
            if c == 0x2D || c == 0x20 { continue } // '-' ' '
            if c == 0x4F { c = 0x30 } // O → 0
            if c == 0x49 || c == 0x4C { c = 0x31 } // I, L → 1
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = buffer << 5 | UInt32(v)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }

    public static func grouped(_ s: String, size: Int = 4) -> String {
        var groups: [String] = []
        var cur = ""
        for c in s {
            cur.append(c)
            if cur.count == size { groups.append(cur); cur = "" }
        }
        if !cur.isEmpty { groups.append(cur) }
        return groups.joined(separator: "-")
    }
}

/// ペアリングコード = ホスト公開鍵の指紋 (80bit) + 使い捨ての秘密 (40bit)。
///
/// - 指紋部分: ビューアはハンドシェイクで受け取ったホスト鍵がこれと一致するか検証する。
///   一致しなければ中間者 (MITM) なので、秘密を一切使わずに切断する。
/// - 秘密部分: 正しいホストに対してだけ「コードを知っている」ことを HMAC で証明する。
///   証明はこの接続のハンドシェイクハッシュに結び付くので、盗み見て再利用できない。
///   総当たりはホスト側で 5 回失敗したらコード自体を無効化して防ぐ。
public struct PairingCode: Equatable {
    public static let fingerprintLength = 10
    public static let secretLength = 5

    public let hostFingerprintPrefix: [UInt8]
    public let secret: [UInt8]

    public init(hostPublicKey: [UInt8]) {
        hostFingerprintPrefix = Array(Fingerprint.digest(hostPublicKey).prefix(Self.fingerprintLength))
        var rng = SystemRandomNumberGenerator()
        secret = (0 ..< Self.secretLength).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
    }

    init(prefix: [UInt8], secret: [UInt8]) {
        hostFingerprintPrefix = prefix
        self.secret = secret
    }

    /// 例: "ABCD-EFGH-JKMN-PQRS-TVWX-YZ01"
    public var string: String {
        Base32.grouped(Base32.encode(hostFingerprintPrefix + secret))
    }

    public static func parse(_ s: String) -> PairingCode? {
        let total = fingerprintLength + secretLength
        guard let bytes = Base32.decode(s), bytes.count == total else { return nil }
        return PairingCode(prefix: Array(bytes.prefix(fingerprintLength)), secret: Array(bytes.suffix(secretLength)))
    }

    public func matches(hostPublicKey: [UInt8]) -> Bool {
        Array(Fingerprint.digest(hostPublicKey).prefix(Self.fingerprintLength)) == hostFingerprintPrefix
    }

    private static let proofLabel = Array("RemoteDesktop pairing proof v1".utf8)

    /// ビューアがホストに送る証明
    public func proof(handshakeHash: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Self.proofLabel + handshakeHash, using: SymmetricKey(data: secret)))
    }

    /// ホスト側の検証 (定数時間比較)
    public func verify(proof: [UInt8], handshakeHash: [UInt8]) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Self.proofLabel + handshakeHash,
                                               using: SymmetricKey(data: secret))
    }
}
