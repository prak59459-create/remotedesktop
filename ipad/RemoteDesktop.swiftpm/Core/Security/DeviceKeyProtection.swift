// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/Security/DeviceKeyProtection.swift からコピー。直接編集しないでください。
#if os(iOS) || os(macOS)
import Foundation
import LocalAuthentication
import Security

/// 端末の秘密鍵 (X25519) を、接続のたびに本人確認しないと使えないように保管する。
///
/// 1. Secure Enclave に P-256 の鍵を作る (取り出し不可・この端末のみ・使うたびに Face ID / Touch ID)。
///    生体情報を登録し直すと無効になる (biometryCurrentSet)。生体認証が無い端末ではパスコード。
/// 2. X25519 の秘密鍵をその公開鍵で暗号化 (ECIES) し、暗号文だけをキーチェーンに置く。
/// 3. 接続時に Secure Enclave で復号する → ここで Face ID が求められる。
///
/// iPad を拾われても、持ち主の顔 (指) が無ければ鍵を取り出せず、PC には接続できない。
/// Secure Enclave が使えない環境 (シミュレータ、署名のない Mac アプリ) では、
/// キーチェーンに置いたうえで、使う前にアプリ側で本人確認する (softwareGate)。
public enum DeviceKeyProtection {
    public enum Level: String {
        case secureEnclave = "Secure Enclave + 生体認証"
        case softwareGate = "キーチェーン + 本人確認"
        case none = "保護なし (この端末にパスコードが設定されていません)"
    }

    public enum Failure: Error, CustomStringConvertible {
        case notAuthenticated
        case keyInvalidated
        case keychain(String)
        public var description: String {
            switch self {
            case .keyInvalidated:
                return "端末の鍵が使えなくなっています (Face ID を登録し直した場合など)。「端末の鍵をリセット」してからペアリングし直してください"
            case .notAuthenticated:
                return "本人確認ができなかったため、接続を中止しました (Face ID を登録し直した場合は「端末の鍵をリセット」してください)"
            case .keychain(let s): return "鍵の保管に失敗しました: \(s)"
            }
        }
    }

    private static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    /// 鍵を取り出す (無ければ作る)。reason は Face ID の画面に出る説明。
    public static func loadOrCreateIdentity(name: String, reason: String) throws -> (StaticIdentity, Level) {
        let tag = Data("RemoteDesktop.\(name).wrap".utf8)
        let sealedName = name + ".sealed"

        // すでに Secure Enclave で包んだ鍵がある
        if let sealed = try SecretStore.load(name: sealedName) {
            let context = LAContext()
            context.localizedReason = reason
            guard let wrapKey = enclaveKey(tag: tag, context: context) else {
                throw Failure.keyInvalidated
            }
            var err: Unmanaged<CFError>?
            guard let raw = SecKeyCreateDecryptedData(wrapKey, algorithm, Data(sealed) as CFData, &err) as Data? else {
                throw Failure.notAuthenticated
            }
            return (try StaticIdentity(rawPrivateKey: [UInt8](raw)), .secureEnclave)
        }

        // 新しく作る: 古い Secure Enclave の鍵が残っていれば消してから (同じタグの鍵を重ねない)
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
        if let wrapKey = createEnclaveKey(tag: tag), let pub = SecKeyCopyPublicKey(wrapKey),
           SecKeyIsAlgorithmSupported(pub, .encrypt, algorithm) {
            let id = StaticIdentity.generate()
            var err: Unmanaged<CFError>?
            if let sealed = SecKeyCreateEncryptedData(pub, algorithm, Data(id.rawPrivateKey) as CFData, &err) as Data? {
                try SecretStore.save(name: sealedName, bytes: [UInt8](sealed))
                return (id, .secureEnclave)
            }
        }

        // 使えない環境: キーチェーン + アプリ側の本人確認
        let level: Level = try authenticate(reason: reason) ? .softwareGate : .none
        return (try SecretStore.loadOrCreateIdentity(name: name + ".keychain"), level)
    }

    /// 端末の鍵を消す (Face ID を登録し直して鍵が使えなくなったとき用)。次の接続で新しい鍵を作るので、
    /// ホストとのペアリングをやり直す必要がある。
    public static func reset(name: String) throws {
        let tag = Data("RemoteDesktop.\(name).wrap".utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
        ]
        SecItemDelete(query as CFDictionary) // 同じタグの鍵がいくつあっても全部消す
        try SecretStore.delete(name: name + ".sealed")
        try SecretStore.delete(name: name + ".keychain")
    }

    private static func enclaveKey(tag: Data, context: LAContext) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let ref = out else { return nil }
        return (ref as! SecKey)
    }

    private static func createEnclaveKey(tag: Data) -> SecKey? {
        // 生体認証が使えるなら生体情報に結び付け、無ければパスコード
        let biometry = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let flags: SecAccessControlCreateFlags = biometry ? [.privateKeyUsage, .biometryCurrentSet]
                                                          : [.privateKeyUsage, .devicePasscode]
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           flags, &err) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]
        return SecKeyCreateRandomKey(attrs as CFDictionary, &err)
    }

    /// 本人確認 (生体認証またはパスコード)。端末にパスコードが無ければ false を返す (確認できない)。
    private static func authenticate(reason: String) throws -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            ok = success
            done.signal()
        }
        done.wait()
        guard ok else { throw Failure.notAuthenticated }
        return true
    }
}
#endif
