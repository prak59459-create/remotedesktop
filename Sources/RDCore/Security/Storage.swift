import Foundation

#if os(Windows)
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
        return try dpapi(data, protect: false)
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
        try SecureFile.write(try dpapi(bytes, protect: true), to: url)
        #else
        try SecureFile.write(bytes, to: url)
        #endif
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
@inline(never)
private func SecureZeroMemory(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) {
    for i in 0 ..< n { p[i] = 0 }
}
#endif

/// 信頼する公開鍵の一覧 (JSON)。ホストでは「許可した端末」、ビューアでは「信頼したホスト」。
public final class TrustStore {
    public struct Entry: Codable, Equatable {
        public var publicKey: String // hex
        public var name: String
        public var added: Date
        public var lastSeen: Date?
    }

    private let url: URL
    private let lock = NSLock()
    private var entries: [Entry]

    public init(fileName: String) throws {
        url = try DataDirectory.url().appendingPathComponent(fileName)
        entries = Self.load(url)
    }

    private static func load(_ url: URL) -> [Entry] {
        guard let data = SecureFile.read(url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Entry].self, from: Data(data))) ?? []
    }

    /// ディスクから読み直す (別プロセスでの --revoke を反映するため)
    public func reload() {
        let fresh = Self.load(url)
        lock.lock(); defer { lock.unlock() }
        entries = fresh
    }

    public var all: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func find(publicKey: [UInt8]) -> Entry? {
        let hex = Fingerprint.hex(publicKey)
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.publicKey == hex }
    }

    public func add(publicKey: [UInt8], name: String) throws {
        let hex = Fingerprint.hex(publicKey)
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.publicKey == hex }
        entries.append(Entry(publicKey: hex, name: name, added: Date(), lastSeen: Date()))
        try persist()
    }

    public func touch(publicKey: [UInt8]) {
        let hex = Fingerprint.hex(publicKey)
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.publicKey == hex }) else { return }
        entries[i].lastSeen = Date()
        try? persist()
    }

    /// 指紋 (表示用) または公開鍵 hex の先頭一致で削除。削除件数を返す。
    public func remove(matching query: String) throws -> Int {
        let q = query.uppercased().replacingOccurrences(of: "-", with: "")
        lock.lock(); defer { lock.unlock() }
        let before = entries.count
        entries.removeAll { e in
            guard q.count >= 4, let key = Fingerprint.fromHex(e.publicKey) else { return false }
            let fp = Fingerprint.display(key).replacingOccurrences(of: "-", with: "")
            return fp.hasPrefix(q) || e.publicKey.uppercased().hasPrefix(q)
        }
        try persist()
        return before - entries.count
    }

    private func persist() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.write([UInt8](try enc.encode(entries)), to: url)
    }
}

/// 監査ログ (追記のみ)。相手から来た文字列は制御文字を除去してから書く。
public final class AuditLog {
    private let url: URL?
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public init(fileName: String = "audit.log") {
        url = try? DataDirectory.url().appendingPathComponent(fileName)
    }

    public func record(_ event: String) {
        let line = "\(formatter.string(from: Date())) \(sanitize(event))\n"
        print(line, terminator: "")
        guard let url = url else { return }
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? SecureFile.write([], to: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }
}

/// 相手から受け取った文字列を表示・記録用に無害化する
public func sanitize(_ s: String, maxLength: Int = 200) -> String {
    let cleaned = s.unicodeScalars.map { sc -> Character in
        (sc.properties.generalCategory == .control || sc.properties.generalCategory == .format) ? "?" : Character(sc)
    }
    return String(String(cleaned).prefix(maxLength))
}
