import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// 耐量子のハイブリッド鍵交換 (ML-KEM-768 / FIPS 203)。
//
// Noise XX (X25519) のハンドシェイク直後、すでに暗号化された通路の中で
//   ビューア → ホスト: ML-KEM 公開鍵 (一時鍵)
//   ホスト → ビューア: カプセル化した共有秘密
// を交換し、以降の通信鍵を「X25519 由来の鍵 + ML-KEM の共有秘密」から作り直す。
// 将来、量子計算機で X25519 が破られても、ML-KEM が破られない限り通信は読めない
// (録っておいて後で解読する攻撃への備え)。
// 交換は暗号化・認証済みの通路で行うので、途中で「使わない」ことに書き換える (ダウングレード) ことはできない。
//
// Apple の OS では iOS 26 / macOS 26 以降でだけ使える。古い OS 同士では従来の X25519 のみになる。

public enum PostQuantum {
    public static let publicKeySize = 1184
    public static let ciphertextSize = 1088

    /// この端末で ML-KEM-768 を使えるか
    public static var isAvailable: Bool {
        #if !canImport(CryptoKit)
        return true
        #elseif compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) { return true }
        return false
        #else
        return false
        #endif
    }

    /// ビューア側: 一時鍵を作り、公開鍵を相手に送ってから、受け取った暗号文を開く
    public final class Initiator {
        public let publicKey: [UInt8]
        private let open: ([UInt8]) throws -> [UInt8]

        public init() throws {
            #if !canImport(CryptoKit)
            let k = try MLKEM768.PrivateKey()
            publicKey = Array(k.publicKey.rawRepresentation)
            open = { ct in try k.decapsulate(ct).withUnsafeBytes { Array($0) } }
            #elseif compiler(>=6.2)
            guard #available(macOS 26, iOS 26, *) else { throw NoiseError.invalidState }
            let k = try MLKEM768.PrivateKey()
            publicKey = Array(k.publicKey.rawRepresentation)
            open = { ct in try k.decapsulate(ct).withUnsafeBytes { Array($0) } }
            #else
            throw NoiseError.invalidState
            #endif
        }

        public func decapsulate(_ ciphertext: [UInt8]) throws -> [UInt8] {
            guard ciphertext.count == PostQuantum.ciphertextSize else { throw NoiseError.malformed("ML-KEM 暗号文の長さ") }
            return try open(ciphertext)
        }
    }

    /// ホスト側: 相手の公開鍵で共有秘密をカプセル化する
    public static func encapsulate(to publicKey: [UInt8]) throws -> (ciphertext: [UInt8], secret: [UInt8]) {
        guard publicKey.count == publicKeySize else { throw NoiseError.malformed("ML-KEM 公開鍵の長さ") }
        #if !canImport(CryptoKit)
        let r = try MLKEM768.PublicKey(rawRepresentation: publicKey).encapsulate()
        return (Array(r.encapsulated), r.sharedSecret.withUnsafeBytes { Array($0) })
        #elseif compiler(>=6.2)
        guard #available(macOS 26, iOS 26, *) else { throw NoiseError.invalidState }
        let r = try MLKEM768.PublicKey(rawRepresentation: publicKey).encapsulate()
        return (Array(r.encapsulated), r.sharedSecret.withUnsafeBytes { Array($0) })
        #else
        throw NoiseError.invalidState
        #endif
    }
}
