import Foundation
import XCTest
@testable import RDCore
@testable import RDHostKit

final class HostSettingsTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rdsettings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        DataDirectory.overridePath = tmpDir.path
    }

    override func tearDown() {
        DataDirectory.overridePath = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 署名付きで保存した設定は読める。書き換えると既定値になり、改ざんとして扱われる
    func testSettingsAreSignedAndTamperingIsDetected() throws {
        let key = try HostSettings.integrityKey()
        var s = HostSettings()
        s.relayURL = "https://relay.example.com"
        s.confirm = true
        try s.save(key: key)
        let (loaded, problem) = HostSettings.load(key: key)
        XCTAssertNil(problem)
        XCTAssertEqual(loaded, s)

        // 中継先と「接続のたびに確認」を書き換える
        let url = tmpDir.appendingPathComponent("host_settings.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "relay.example.com", with: "evil.example.com")
            .replacingOccurrences(of: "\\\"confirm\\\":true", with: "\\\"confirm\\\":false")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let (fallback, p2) = HostSettings.load(key: key)
        XCTAssertEqual(p2, .tampered)
        XCTAssertEqual(fallback, HostSettings())

        // 署名のない古い形式は「古い形式」として扱い、中身は使わない
        try JSONEncoder().encode(s).write(to: url)
        XCTAssertEqual(HostSettings.load(key: key).problem, .unsigned)
        XCTAssertEqual(HostSettings.load(key: key).settings, HostSettings())

        // 別の鍵 (別の PC) で署名されたものも受け付けない
        try s.save(key: [UInt8](repeating: 1, count: 32))
        XCTAssertEqual(HostSettings.load(key: key).problem, .tampered)
    }
}
