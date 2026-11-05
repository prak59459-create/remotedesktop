import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if os(Windows)
import CWinSys
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
#endif

public enum StorageError: Error, CustomStringConvertible {
    case io(String)
    case platform(String)

    public var description: String {
        switch self {
        case .io(let s): return "保存領域のエラー: \(s)"
        case .platform(let s): return "鍵保管のエラー: \(s)"
        }
    }
}

/// 設定・鍵の保存先。
///   Windows: %LOCALAPPDATA%\RemoteDesktop (既定 ACL で本人と SYSTEM / Administrators のみ)
///   macOS:   ~/Library/Application Support/RemoteDesktop
///   Linux:   $XDG_CONFIG_HOME/remotedesktop または ~/.config/remotedesktop
/// 環境変数 RD_DATA_DIR で上書きできる (テスト・複数インスタンス用)。
public enum DataDirectory {
    public static var overridePath: String? = ProcessInfo.processInfo.environment["RD_DATA_DIR"]

    public static func url() throws -> URL {
        let url: URL
        let env = ProcessInfo.processInfo.environment
        if let o = overridePath, !o.isEmpty {
            url = URL(fileURLWithPath: o, isDirectory: true)
        } else {
            #if os(Windows)
            guard let base = env["LOCALAPPDATA"] else { throw StorageError.io("LOCALAPPDATA が未設定") }
            url = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("RemoteDesktop", isDirectory: true)
            #elseif canImport(Darwin)
            // macOS: ~/Library/Application Support/RemoteDesktop、iPadOS: アプリのサンドボックス内
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw StorageError.io("Application Support が見つかりません")
            }
            url = base.appendingPathComponent("RemoteDesktop", isDirectory: true)
            #else
            let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
            url = base.appendingPathComponent("remotedesktop", isDirectory: true)
            #endif
        }
        do {
            #if os(Windows)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #else
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            #endif
        } catch {
            throw StorageError.io("\(url.path) を作れません: \(error)")
        }
        return url
    }
}

/// 本人だけが読めるファイルとして原子的に書き込む
public enum SecureFile {
    public static func write(_ bytes: [UInt8], to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        #if os(Windows)
        guard fm.createFile(atPath: tmp.path, contents: Data(bytes)) else { throw StorageError.io("書き込み失敗: \(tmp.path)") }
        #else
        guard fm.createFile(atPath: tmp.path, contents: Data(bytes), attributes: [.posixPermissions: 0o600]) else {
            throw StorageError.io("書き込み失敗: \(tmp.path)")
        }
        #endif
        // 既存ファイルを原子的に置き換える (途中で落ちても壊れたファイルが残らない)
        #if os(Windows)
        let ok = tmp.path.withCString(encodedAs: UTF16.self) { src in
            url.path.withCString(encodedAs: UTF16.self) { dst in
                MoveFileExW(src, dst, DWORD(0x1 | 0x8)) // MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
            }
        }
        guard ok else { throw StorageError.io("保存失敗: \(url.path) (error \(GetLastError()))") }
        #else
        guard rename(tmp.path, url.path) == 0 else { throw StorageError.io("保存失敗: \(url.path) (errno \(errno))") }
        #endif
    }

    public static func read(_ url: URL) -> [UInt8]? {
        guard let d = FileManager.default.contents(atPath: url.path) else { return nil }
        return [UInt8](d)
    }
}

/// 秘密鍵の保管。
///   Windows: DPAPI (CryptProtectData) でユーザーのログオン資格情報に紐付けて暗号化してからファイルへ
///   macOS / iPadOS: キーチェーン (このデバイスのみ・ロック解除中のみ取り出し可)
///   その他:  パーミッション 0600 のファイル
public enum SecretStore {
    public static func loadOrCreateIdentity(name: String) throws -> StaticIdentity {
        if let raw = try load(name: name) {
            return try StaticIdentity(rawPrivateKey: raw)
        }
        let id = StaticIdentity.generate()
        try save(name: name, bytes: id.rawPrivateKey)
        return id
    }

    /// ランダムな秘密 (部屋トークン、改ざん検知の鍵など)。created = 今回初めて作ったか
    public static func loadOrCreateSecret(name: String, size: Int = 32) throws -> (bytes: [UInt8], created: Bool) {
        if let raw = try load(name: name), raw.count == size { return (raw, false) }
        var rng = SystemRandomNumberGenerator()
        let bytes = (0 ..< size).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
        try save(name: name, bytes: bytes)
        return (bytes, true)
    }

    static var useKeychain: Bool {
        #if os(macOS) || os(iOS)
        return DataDirectory.overridePath == nil
        #else
        return false
        #endif
    }

    public static func load(name: String) throws -> [UInt8]? {
        #if os(macOS) || os(iOS)
        if useKeychain { return try keychainLoad(name) }
        #endif
        let url = try DataDirectory.url().appendingPathComponent(fileName(name))
        guard let data = SecureFile.read(url) else { return nil }
        #if os(Windows)
        return try TPMWrap.unwrap(try dpapi(data, protect: false))
        #else
        return data
        #endif
    }

    public static func save(name: String, bytes: [UInt8]) throws {
        #if os(macOS) || os(iOS)
        if useKeychain { return try keychainSave(name, bytes) }
        #endif
        let url = try DataDirectory.url().appendingPathComponent(fileName(name))
        #if os(Windows)
        // TPM があれば TPM 内の鍵で包んでから DPAPI。どちらか片方だけでは取り出せない
        try SecureFile.write(try dpapi(TPMWrap.wrap(bytes), protect: true), to: url)
        #else
        try SecureFile.write(bytes, to: url)
        #endif
    }

    public static func delete(name: String) throws {
        #if os(macOS) || os(iOS)
        if useKeychain {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: name] as CFDictionary)
            return
        }
        #endif
        let url = try DataDirectory.url().appendingPathComponent(fileName(name))
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileName(_ name: String) -> String {
        #if os(Windows)
        return name + ".dpapi"
        #else
        return name + ".key"
        #endif
    }

    #if os(Windows)
    private static func dpapi(_ input: [UInt8], protect: Bool) throws -> [UInt8] {
        var copy = input
        return try copy.withUnsafeMutableBufferPointer { buf -> [UInt8] in
            var inBlob = DATA_BLOB(cbData: DWORD(buf.count), pbData: buf.baseAddress)
            var outBlob = DATA_BLOB(cbData: 0, pbData: nil)
            let flags = DWORD(0x1) // CRYPTPROTECT_UI_FORBIDDEN
            let ok = protect
                ? CryptProtectData(&inBlob, nil, nil, nil, nil, flags, &outBlob)
                : CryptUnprotectData(&inBlob, nil, nil, nil, nil, flags, &outBlob)
            guard ok, let p = outBlob.pbData else {
                throw StorageError.platform("DPAPI \(protect ? "暗号化" : "復号") 失敗 (error \(GetLastError()))")
            }
            defer {
                SecureZeroMemory(p, Int(outBlob.cbData))
                _ = LocalFree(UnsafeMutableRawPointer(p))
            }
            return Array(UnsafeBufferPointer(start: p, count: Int(outBlob.cbData)))
        }
    }
    #endif

    #if os(macOS) || os(iOS)
    private static let service = "RemoteDesktop"

    private static func keychainLoad(_ name: String) throws -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw StorageError.platform("キーチェーン読み出し失敗 (OSStatus \(status))")
        }
        return [UInt8](data)
    }

    private static func keychainSave(_ name: String, _ bytes: [UInt8]) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(bytes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StorageError.platform("キーチェーン保存失敗 (OSStatus \(status))") }
    }
    #endif
}

#if os(Windows)
/// TPM 2.0 (Microsoft Platform Crypto Provider) の取り出せない RSA 鍵で秘密を包む。
/// ディスクの中身を丸ごと別の PC に持ち出しても、その PC の TPM が無いと開けない。
/// TPM が使えない PC では包まずに返す (DPAPI だけで守る)。
enum TPMWrap {
    static let header: [UInt8] = Array("RDTPM1".utf8)
    static let keyName = "RemoteDesktop.KeyWrap"
    private static let lock = NSLock()

    private static func w<T>(_ s: String, _ body: (UnsafePointer<UInt16>) -> T) -> T {
        s.withCString(encodedAs: UTF16.self, body)
    }

    /// TPM の鍵を開く (無ければ作る)。使えなければ nil
    private static func openKey(create: Bool) -> NCRYPT_KEY_HANDLE? {
        var prov: NCRYPT_PROV_HANDLE = 0
        guard w("Microsoft Platform Crypto Provider", { NCryptOpenStorageProvider(&prov, $0, 0) }) == 0 else { return nil }
        defer { _ = NCryptFreeObject(prov) }
        var key: NCRYPT_KEY_HANDLE = 0
        if w(keyName, { NCryptOpenKey(prov, &key, $0, 0, 0) }) == 0 { return key }
        guard create else { return nil }
        guard w("RSA", { alg in w(keyName, { NCryptCreatePersistedKey(prov, &key, alg, $0, 0, 0) }) }) == 0 else { return nil }
        var bits: DWORD = 2048
        _ = withUnsafeMutableBytes(of: &bits) { b in
            w("Length", { NCryptSetProperty(key, $0, b.baseAddress!.assumingMemoryBound(to: UInt8.self), 4, 0) })
        }
        guard NCryptFinalizeKey(key, 0) == 0 else {
            _ = NCryptFreeObject(key)
            return nil
        }
        return key
    }

    private static func crypt(_ key: NCRYPT_KEY_HANDLE, _ input: [UInt8], encrypt: Bool) -> [UInt8]? {
        var src = input
        return w("SHA256") { alg -> [UInt8]? in
            var pad = BCRYPT_OAEP_PADDING_INFO(pszAlgId: alg, pbLabel: nil, cbLabel: 0)
            let flags: DWORD = 0x4 // NCRYPT_PAD_OAEP_FLAG
            var size: DWORD = 0
            let st1 = src.withUnsafeMutableBufferPointer { s in
                encrypt ? NCryptEncrypt(key, s.baseAddress, DWORD(s.count), &pad, nil, 0, &size, flags)
                        : NCryptDecrypt(key, s.baseAddress, DWORD(s.count), &pad, nil, 0, &size, flags)
            }
            guard st1 == 0, size > 0 else { return nil }
            var out = [UInt8](repeating: 0, count: Int(size))
            let st2 = src.withUnsafeMutableBufferPointer { s in
                out.withUnsafeMutableBufferPointer { o in
                    encrypt ? NCryptEncrypt(key, s.baseAddress, DWORD(s.count), &pad, o.baseAddress, DWORD(o.count), &size, flags)
                            : NCryptDecrypt(key, s.baseAddress, DWORD(s.count), &pad, o.baseAddress, DWORD(o.count), &size, flags)
                }
            }
            guard st2 == 0 else { return nil }
            return Array(out.prefix(Int(size)))
        }
    }

    static func wrap(_ secret: [UInt8]) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard secret.count <= 190, let key = openKey(create: true) else { return secret }
        defer { _ = NCryptFreeObject(key) }
        guard let sealed = crypt(key, secret, encrypt: true) else { return secret }
        return header + sealed
    }

    static func unwrap(_ blob: [UInt8]) throws -> [UInt8] {
        guard blob.starts(with: header) else { return blob } // TPM なしで保存したもの
        lock.lock(); defer { lock.unlock() }
        guard let key = openKey(create: false) else {
            throw StorageError.platform("TPM の鍵が見つかりません (別の PC にコピーされた可能性があります)")
        }
        defer { _ = NCryptFreeObject(key) }
        guard let plain = crypt(key, Array(blob.dropFirst(header.count)), encrypt: false) else {
            throw StorageError.platform("TPM で鍵を復号できません")
        }
        return plain
    }
}

@inline(never)
private func SecureZeroMemory(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) {
    for i in 0 ..< n { p[i] = 0 }
}
#endif

/// 信頼する公開鍵の一覧 (JSON)。ホストでは「許可した端末」、ビューアでは「信頼したホスト」。
///
/// integrityKey を渡すと、一覧に HMAC-SHA256 を付けて保存し、読むたびに検証する。
/// 鍵は DPAPI / キーチェーンで保護されるので、ファイルだけを書き換えて端末を追加することはできない。
/// 検証に失敗したら isTampered になり、ホストはすべての接続を拒否する。
public final class TrustStore {
    public struct Entry: Codable, Equatable {
        public var publicKey: String // hex
        public var name: String
        public var added: Date
        public var lastSeen: Date?
        /// ビューア側: このホストの中継サーバー上の部屋 ID (ホストから暗号化して受け取る)
        public var relayRoom: String?
    }

    public enum StoreError: Error, CustomStringConvertible {
        case tampered
        public var description: String {
            "許可端末の一覧が改ざんされています。RDHost --reset-devices で作り直し、端末をペアリングし直してください"
        }
    }

    /// 署名付きのファイル形式
    private struct Signed: Codable {
        var version: Int
        var entries: String // [Entry] の JSON そのもの (署名対象)
        var mac: String
    }

    private let url: URL
    private let lock = NSLock()
    private let integrityKey: [UInt8]?
    private var entries: [Entry]
    public private(set) var isTampered = false

    /// - integrityKey: 改ざん検知に使う秘密。ホストではホストの秘密鍵から導出する (HostIdentity.trustStoreKey)。
    ///   独立したファイルにすると、それだけ消して作り直させる迂回ができてしまうため。
    ///   署名のない一覧は、鍵を渡した場合は常に改ざん扱い (古い形式への移行は受け付けない)。
    public init(fileName: String, integrityKey: [UInt8]? = nil) throws {
        url = try DataDirectory.url().appendingPathComponent(fileName)
        self.integrityKey = integrityKey
        let (e, t) = Self.load(url, key: integrityKey)
        entries = e
        isTampered = t
    }

    /// ホストの秘密鍵から、許可一覧の改ざん検知用の鍵を導出する
    public static func integrityKey(for identity: StaticIdentity) -> [UInt8] {
        noiseHMAC(key: identity.rawPrivateKey, Array("RemoteDesktop trust store key v1".utf8))
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func mac(_ bytes: [UInt8], key: [UInt8]) -> [UInt8] {
        noiseHMAC(key: key, Array("RemoteDesktop trust store v1".utf8) + bytes)
    }

    private static func load(_ url: URL, key: [UInt8]?) -> ([Entry], Bool) {
        guard let data = SecureFile.read(url), !data.isEmpty else { return ([], false) }
        if let signed = try? decoder().decode(Signed.self, from: Data(data)) {
            let body = Array(signed.entries.utf8)
            if let key = key {
                guard let given = Fingerprint.fromHex(signed.mac),
                      constantTimeEqual(given, mac(body, key: key)) else { return ([], true) }
            }
            guard let e = try? decoder().decode([Entry].self, from: Data(body)) else { return ([], true) }
            return (e, false)
        }
        if let legacy = try? decoder().decode([Entry].self, from: Data(data)) {
            // 署名が必要なのに署名がない = 書き換えられた可能性
            if key != nil { return ([], true) }
            return (legacy, false)
        }
        return ([], key != nil)
    }

    /// ディスクから読み直す (別プロセスでの --revoke を反映するため)
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        reloadLocked()
    }

    private func reloadLocked() {
        let (fresh, t) = Self.load(url, key: integrityKey)
        entries = fresh
        isTampered = t
    }

    public var all: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func find(publicKey: [UInt8]) -> Entry? {
        let hex = Fingerprint.hex(publicKey)
        lock.lock(); defer { lock.unlock() }
        guard !isTampered else { return nil }
        return entries.first { $0.publicKey == hex }
    }

    public func add(publicKey: [UInt8], name: String, relayRoom: String? = nil) throws {
        let hex = Fingerprint.hex(publicKey)
        lock.lock(); defer { lock.unlock() }
        reloadLocked() // 別プロセスでの変更 (--revoke など) を上書きしない
        guard !isTampered else { throw StoreError.tampered }
        let old = entries.first { $0.publicKey == hex }
        entries.removeAll { $0.publicKey == hex }
        entries.append(Entry(publicKey: hex, name: name, added: old?.added ?? Date(), lastSeen: Date(),
                             relayRoom: relayRoom ?? old?.relayRoom))
        try persist()
    }

    /// ビューア側: ホストから受け取った中継の部屋 ID を記録する
    public func setRelayRoom(publicKey: [UInt8], room: String) throws {
        let hex = Fingerprint.hex(publicKey)
        lock.lock(); defer { lock.unlock() }
        reloadLocked() // 別プロセスでの変更 (--revoke など) を上書きしない
        guard !isTampered, let i = entries.firstIndex(where: { $0.publicKey == hex }) else { return }
        guard entries[i].relayRoom != room else { return }
        entries[i].relayRoom = room
        try persist()
    }

    public func touch(publicKey: [UInt8]) {
        let hex = Fingerprint.hex(publicKey)
        lock.lock(); defer { lock.unlock() }
        reloadLocked() // 別プロセスでの変更 (--revoke など) を上書きしない
        guard !isTampered, let i = entries.firstIndex(where: { $0.publicKey == hex }) else { return }
        entries[i].lastSeen = Date()
        try? persist()
    }

    /// 指紋 (表示用) または公開鍵 hex の先頭一致で削除。削除件数を返す。
    public func remove(matching query: String) throws -> Int {
        let q = query.uppercased().replacingOccurrences(of: "-", with: "")
        lock.lock(); defer { lock.unlock() }
        reloadLocked() // 別プロセスでの変更 (--revoke など) を上書きしない
        guard !isTampered else { throw StoreError.tampered }
        let before = entries.count
        entries.removeAll { e in
            guard q.count >= 4, let key = Fingerprint.fromHex(e.publicKey) else { return false }
            let fp = Fingerprint.display(key).replacingOccurrences(of: "-", with: "")
            return fp.hasPrefix(q) || e.publicKey.uppercased().hasPrefix(q)
        }
        try persist()
        return before - entries.count
    }

    /// 一覧を空にして署名し直す (改ざんを検知したあとの復旧用)
    public func reset() throws {
        lock.lock(); defer { lock.unlock() }
        entries = []
        isTampered = false
        try persist()
    }

    private func persist() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body = try enc.encode(entries)
        if let key = integrityKey {
            let text = String(decoding: body, as: UTF8.self)
            let signed = Signed(version: 2, entries: text, mac: Fingerprint.hex(Self.mac(Array(body), key: key)))
            try SecureFile.write([UInt8](try enc.encode(signed)), to: url)
        } else {
            try SecureFile.write([UInt8](body), to: url)
        }
    }
}

/// 長さが同じなら、内容によらず同じ時間で比較する
public func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0 ..< a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

/// 監査ログ (追記のみ)。相手から来た文字列は制御文字を除去してから書く。
///
/// 各行の末尾に「直前の行までを含めたハッシュ」を付けたハッシュチェーンにする。
/// 途中の行を書き換えたり消したりすると、それ以降のハッシュが合わなくなる (AuditLog.verify)。
/// 末尾を丸ごと消す改ざんは検出できないので、重要な記録は Windows イベントログにも写す (mirror)。
public final class AuditLog {
    private let url: URL?
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private var lastHash: [UInt8]
    /// 写し先 (Windows イベントログなど)。第 2 引数は警告扱いにするか
    public var mirror: ((String, Bool) -> Void)?

    static let genesis = [UInt8](repeating: 0, count: 32)
    static let marker = " #"

    public init(fileName: String = "audit.log") {
        url = try? DataDirectory.url().appendingPathComponent(fileName)
        lastHash = Self.genesis
        if let u = url, let data = SecureFile.read(u) {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            if let last = lines.last, let r = last.range(of: Self.marker, options: .backwards),
               let h = Fingerprint.fromHex(String(last[r.upperBound...])), h.count == 32 {
                lastHash = h
            }
        }
    }

    static func chain(_ prev: [UInt8], _ body: String) -> [UInt8] {
        var h = SHA256()
        h.update(data: prev)
        h.update(data: Array(body.utf8))
        return Array(h.finalize())
    }

    public func record(_ event: String) {
        let body = "\(formatter.string(from: Date())) \(sanitize(event, maxLength: 400))"
        print(body)
        let important = ["REJECT", "BLOCKED", "TAMPER", "PAIRED", "REVOKED", "KILLED", "RESET"].contains { event.contains($0) }
        mirror?(body, important)
        guard let url = url else { return }
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? SecureFile.write([], to: url)
        }
        guard let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        // 直前の行のハッシュはファイルの末尾から読む。別のプロセス (RDHost --revoke など) が
        // 追記していても、チェーンが分岐しないように。
        let prev = Self.lastHash(in: fh) ?? lastHash
        let h = Self.chain(prev, body)
        lastHash = h
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data((body + Self.marker + Fingerprint.hex(h) + "\n").utf8))
    }

    /// ファイル末尾の行からハッシュを読む
    static func lastHash(in fh: FileHandle) -> [UInt8]? {
        guard let end = try? fh.seekToEnd(), end > 0 else { return genesis }
        let start = end > 4096 ? end - 4096 : 0
        try? fh.seek(toOffset: start)
        guard let tail = try? fh.readToEnd() else { return nil }
        let lines = String(decoding: tail, as: UTF8.self).split(separator: "\n")
        guard let last = lines.last, let r = last.range(of: marker, options: .backwards),
              let h = Fingerprint.fromHex(String(last[r.upperBound...])), h.count == 32 else { return nil }
        return h
    }

    public enum Verification: Equatable {
        case ok(lines: Int)
        case broken(atLine: Int)
        case missing
    }

    /// ハッシュチェーンを先頭から検証する
    public static func verify(fileName: String = "audit.log") -> Verification {
        guard let url = try? DataDirectory.url().appendingPathComponent(fileName),
              let data = SecureFile.read(url) else { return .missing }
        var prev = genesis
        var n = 0
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            n += 1
            guard let r = raw.range(of: marker, options: .backwards),
                  let h = Fingerprint.fromHex(String(raw[r.upperBound...])) else { return .broken(atLine: n) }
            let body = String(raw[..<r.lowerBound])
            let expected = chain(prev, body)
            guard constantTimeEqual(h, expected) else { return .broken(atLine: n) }
            prev = expected
        }
        return .ok(lines: n)
    }
}

/// 相手から受け取った文字列を表示・記録用に無害化する
public func sanitize(_ s: String, maxLength: Int = 200) -> String {
    let cleaned = s.unicodeScalars.map { sc -> Character in
        (sc.properties.generalCategory == .control || sc.properties.generalCategory == .format) ? "?" : Character(sc)
    }
    return String(String(cleaned).prefix(maxLength))
}
