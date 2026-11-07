import Foundation
import XCTest
@testable import RDCore
@testable import RDHostKit

/// ホストのセッション (画面配信 + 入力) の安全上の振る舞い
final class HostSessionTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rdhostkit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        DataDirectory.overridePath = tmpDir.path
    }

    override func tearDown() {
        DataDirectory.overridePath = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private struct Host {
        let gate: HostGatekeeper
        let clients: TrustStore
        let port: UInt16
        let identity: StaticIdentity
        let ended: XCTestExpectation
    }

    /// 1 回だけ接続を受け付けて、本物の HostSession を動かすホスト
    private func startHost(_ options: HostOptions) throws -> Host {
        let id = StaticIdentity.generate()
        let clients = try TrustStore(fileName: "authorized_devices.json")
        let gate = HostGatekeeper(identity: id, clients: clients, audit: AuditLog())
        gate.handshakeTimeout = 3
        let listener = try TCPListener(port: 0, bindAddress: "127.0.0.1")
        let ended = expectation(description: "セッションが終わる")
        Thread {
            defer { listener.close() }
            guard let c = try? listener.accept(), let client = try? gate.authenticate(c) else { return }
            HostSession(client: client, gate: gate, options: options, audit: AuditLog()).run()
            ended.fulfill()
        }.start()
        return Host(gate: gate, clients: clients, port: listener.boundPort, identity: id, ended: ended)
    }

    private func connect(_ host: Host, as viewer: StaticIdentity) throws -> ViewerConnector.Session {
        let known = try TrustStore(fileName: "trusted_hosts.json")
        try known.add(publicKey: host.identity.publicKey, name: "host")
        return try ViewerConnector.connect(host: "127.0.0.1", port: host.port, identity: viewer, knownHosts: known,
                                           pairingCode: nil, deviceName: "attacker")
    }

    /// 回帰テスト: 画面データを受け取らずに ack と全画面の要求だけを送り続ける端末でも、
    /// 登録を取り消せば切断される (送信が詰まっていても、失効の確認が止まらない)
    func testRevokedViewerThatStopsReadingIsDisconnected() throws {
        var options = HostOptions()
        options.fps = 60
        options.statsInterval = 0
        let host = try startHost(options)
        let viewer = StaticIdentity.generate()
        try host.clients.add(publicKey: viewer.publicKey, name: "attacker")
        let session = try connect(host, as: viewer)

        let stop = NSLock()
        var stopped = false
        Thread {
            // 受信はしない。ホストの送信を止めないように ack を返し、全画面を要求し続ける
            while true {
                stop.lock(); let s = stopped; stop.unlock()
                if s { return }
                try? session.channel.send(.requestKeyframe)
                try? session.channel.send(.frameAck)
                usleep(2000)
            }
        }.start()
        defer { stop.lock(); stopped = true; stop.unlock(); session.channel.close() }

        // 送信バッファが埋まって、ホストが送信で止まるまで待つ
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(ActiveSessions.shared.current.contains("attacker"), "取り消す前はまだ接続している")
        XCTAssertEqual(try host.clients.remove(matching: Fingerprint.display(viewer.publicKey)), 1)
        // 失効の確認は 1 秒ごと。少し余裕を見て 8 秒以内に終わること
        wait(for: [host.ended], timeout: 8)
        XCTAssertTrue(auditLog().contains("reason=device_revoked"), auditLog())
    }

    private func auditLog() -> String {
        (try? String(contentsOf: tmpDir.appendingPathComponent("audit.log"), encoding: .utf8)) ?? ""
    }

    /// 最長時間を過ぎたら、受信を止めている端末でも切断される
    func testMaxSessionEndsEvenIfViewerStopsReading() throws {
        var options = HostOptions()
        options.fps = 60
        options.statsInterval = 0
        options.maxSession = 3
        let host = try startHost(options)
        let viewer = StaticIdentity.generate()
        try host.clients.add(publicKey: viewer.publicKey, name: "attacker")
        let session = try connect(host, as: viewer)
        let stop = NSLock()
        var stopped = false
        Thread {
            while true {
                stop.lock(); let s = stopped; stop.unlock()
                if s { return }
                try? session.channel.send(.requestKeyframe)
                try? session.channel.send(.frameAck)
                usleep(2000)
            }
        }.start()
        defer { stop.lock(); stopped = true; stop.unlock(); session.channel.close() }
        wait(for: [host.ended], timeout: 10)
        XCTAssertTrue(auditLog().contains("reason=max_session"), auditLog())
    }
}
