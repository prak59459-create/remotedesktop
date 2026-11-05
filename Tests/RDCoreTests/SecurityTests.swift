#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import RDCore

final class SecurityTests: XCTestCase {
    private var tmpDir: URL!
    private static var nextPort: UInt16 = 47200

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rdtest-\(UUID().uuidString)")
        DataDirectory.overridePath = tmpDir.path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        DataDirectory.overridePath = nil
    }

    private func port() -> UInt16 {
        Self.nextPort += 1
        return Self.nextPort
    }

    // MARK: Noise

    func testNoiseXXHandshakeAgreesOnKeysAndIdentities() throws {
        let a = StaticIdentity.generate(), b = StaticIdentity.generate()
        let i = NoiseXXHandshake(role: .initiator, staticKey: a.privateKey, prologue: rdPrologue)
        let r = NoiseXXHandshake(role: .responder, staticKey: b.privateKey, prologue: rdPrologue)
        _ = try r.readMessage(try i.writeMessage())
        _ = try i.readMessage(try r.writeMessage())
        _ = try r.readMessage(try i.writeMessage())
        XCTAssertTrue(i.isComplete && r.isComplete)
        XCTAssertEqual(i.remoteStaticKey, b.publicKey)
        XCTAssertEqual(r.remoteStaticKey, a.publicKey)
        XCTAssertEqual(i.handshakeHash, r.handshakeHash)

        var (iSend, iRecv) = try i.split()
        var (rSend, rRecv) = try r.split()
        let ct = try iSend.encrypt(ad: [], Array("hello".utf8))
        XCTAssertEqual(try rRecv.decrypt(ad: [], ct), Array("hello".utf8))
        let ct2 = try rSend.encrypt(ad: [], [1, 2, 3])
        XCTAssertEqual(try iRecv.decrypt(ad: [], ct2), [1, 2, 3])
        // 同じ暗号文の再送 (リプレイ) は nonce が進んでいるので失敗する
        XCTAssertThrowsError(try rRecv.decrypt(ad: [], ct))
    }

    func testNoiseDetectsTamperingAndPrologueMismatch() throws {
        let a = StaticIdentity.generate(), b = StaticIdentity.generate()
        // 2 通目の 1 バイトを改ざん
        do {
            let i = NoiseXXHandshake(role: .initiator, staticKey: a.privateKey, prologue: rdPrologue)
            let r = NoiseXXHandshake(role: .responder, staticKey: b.privateKey, prologue: rdPrologue)
            _ = try r.readMessage(try i.writeMessage())
            var m2 = try r.writeMessage()
            m2[40] ^= 0x01
            XCTAssertThrowsError(try i.readMessage(m2))
        }
        // プロトコル版 (prologue) が違う相手とは成立しない
        do {
            let i = NoiseXXHandshake(role: .initiator, staticKey: a.privateKey, prologue: Array("v1".utf8))
            let r = NoiseXXHandshake(role: .responder, staticKey: b.privateKey, prologue: rdPrologue)
            _ = try r.readMessage(try i.writeMessage())
            XCTAssertThrowsError(try i.readMessage(try r.writeMessage()))
        }
    }

    /// 公式テストベクタ (cacophony, Noise_XX_25519_ChaChaPoly_SHA256) と完全一致すること
    /// https://github.com/haskell-cryptography/cacophony/blob/master/vectors/cacophony.txt
    func testNoiseMatchesCacophonyTestVector() throws {
        func hex(_ s: String) -> [UInt8] { Fingerprint.fromHex(s)! }
        func key(_ s: String) throws -> Curve25519.KeyAgreement.PrivateKey {
            try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(s))
        }
        let prologue = hex("4a6f686e2047616c74")
        let i = NoiseXXHandshake(role: .initiator,
                                 staticKey: try key("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"),
                                 prologue: prologue,
                                 ephemeralForTesting: try key("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"))
        let r = NoiseXXHandshake(role: .responder,
                                 staticKey: try key("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"),
                                 prologue: prologue,
                                 ephemeralForTesting: try key("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"))
        let messages: [(String, String)] = [
            ("4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573"),
            ("4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad"),
            ("462e20412e20486179656b", "c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a80ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6ae769a1d95941d49b25030"),
            ("4361726c204d656e676572", "96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df"),
            ("4a65616e2d426170746973746520536179", "3e40f15f6f3a46ae446b253bf8b1d9ffb6ed9b174d272328ff91a7e2e5c79c07f5"),
            ("457567656e2042f6686d20766f6e2042617765726b", "eb3f3515110702e047a6c9da4478b6ead94873c11c0f2d710ddb3f09fce024b3a58502ae3f"),
        ]
        // ハンドシェイク (3 通)
        for (n, (pt, ct)) in messages.prefix(3).enumerated() {
            let (w, rd) = n % 2 == 0 ? (i, r) : (r, i)
            let out = try w.writeMessage(payload: hex(pt))
            XCTAssertEqual(Fingerprint.hex(out), ct, "handshake message \(n)")
            XCTAssertEqual(try rd.readMessage(out), hex(pt))
        }
        XCTAssertEqual(Fingerprint.hex(i.handshakeHash), "c8e5f64e846193be2a834104c2a009868d6c9f3bd3c186299888b488b2f1f58e")
        XCTAssertEqual(i.handshakeHash, r.handshakeHash)
        // トランスポート (交互に送信)
        var (iSend, iRecv) = try i.split()
        var (rSend, rRecv) = try r.split()
        for (n, (pt, ct)) in messages.dropFirst(3).enumerated() {
            if n % 2 == 0 { // レスポンダ → イニシエータ
                let out = try rSend.encrypt(ad: [], hex(pt))
                XCTAssertEqual(Fingerprint.hex(out), ct)
                XCTAssertEqual(try iRecv.decrypt(ad: [], out), hex(pt))
            } else {
                let out = try iSend.encrypt(ad: [], hex(pt))
                XCTAssertEqual(Fingerprint.hex(out), ct)
                XCTAssertEqual(try rRecv.decrypt(ad: [], out), hex(pt))
            }
        }
    }

    func testNoiseIsDeterministicGivenEphemeralKeys() throws {
        // 同じ鍵なら同じ出力 (実装の決定性の確認)
        func run() throws -> [UInt8] {
            let s1 = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: [UInt8](repeating: 1, count: 32))
            let s2 = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: [UInt8](repeating: 2, count: 32))
            let e1 = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: [UInt8](repeating: 3, count: 32))
            let e2 = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: [UInt8](repeating: 4, count: 32))
            let i = NoiseXXHandshake(role: .initiator, staticKey: s1, prologue: [], ephemeralForTesting: e1)
            let r = NoiseXXHandshake(role: .responder, staticKey: s2, prologue: [], ephemeralForTesting: e2)
            let m1 = try i.writeMessage()
            _ = try r.readMessage(m1)
            let m2 = try r.writeMessage()
            _ = try i.readMessage(m2)
            let m3 = try i.writeMessage()
            _ = try r.readMessage(m3)
            return m1 + m2 + m3 + i.handshakeHash
        }
        let a = try run()
        XCTAssertEqual(a, try run())
        XCTAssertEqual(a.count, 32 + (32 + 48 + 16) + (48 + 16) + 32)
    }

    // MARK: ペアリングコード

    func testPairingCodeRoundTripAndProof() throws {
        let host = StaticIdentity.generate()
        let code = PairingCode(hostPublicKey: host.publicKey)
        XCTAssertEqual(code.string.count, 24 + 5)
        XCTAssertEqual(PairingCode.parse(code.string.lowercased()), code)
        XCTAssertEqual(PairingCode.parse(code.string.replacingOccurrences(of: "-", with: " ")), code)
        XCTAssertNil(PairingCode.parse("ABCD"))
        XCTAssertTrue(code.matches(hostPublicKey: host.publicKey))
        XCTAssertFalse(code.matches(hostPublicKey: StaticIdentity.generate().publicKey))

        let h = [UInt8](repeating: 7, count: 32)
        let proof = code.proof(handshakeHash: h)
        XCTAssertTrue(code.verify(proof: proof, handshakeHash: h))
        // 別の接続 (別のハンドシェイクハッシュ) では使えない
        XCTAssertFalse(code.verify(proof: proof, handshakeHash: [UInt8](repeating: 8, count: 32)))
        let other = PairingCode(hostPublicKey: host.publicKey)
        XCTAssertFalse(other.verify(proof: proof, handshakeHash: h))
    }

    func testPairingWindowIsSingleUseAndLocksAfterFailures() {
        let host = StaticIdentity.generate()
        let w = PairingWindow(hostPublicKey: host.publicKey, maxFailures: 3)
        let h = [UInt8](repeating: 1, count: 32)
        XCTAssertEqual(w.consume(proof: [UInt8](repeating: 0, count: 32), handshakeHash: h), .wrong)
        XCTAssertEqual(w.consume(proof: w.code.proof(handshakeHash: h), handshakeHash: h), .accepted)
        XCTAssertEqual(w.consume(proof: w.code.proof(handshakeHash: h), handshakeHash: h), .inactive) // 使用済み

        let w2 = PairingWindow(hostPublicKey: host.publicKey, maxFailures: 3)
        for _ in 0 ..< 3 { _ = w2.consume(proof: [UInt8](repeating: 0, count: 32), handshakeHash: h) }
        XCTAssertEqual(w2.consume(proof: w2.code.proof(handshakeHash: h), handshakeHash: h), .inactive)

        let w3 = PairingWindow(hostPublicKey: host.publicKey, lifetime: -1)
        XCTAssertEqual(w3.consume(proof: w3.code.proof(handshakeHash: h), handshakeHash: h), .inactive) // 期限切れ
    }

    func testTrustStorePersistsAcrossUpdates() throws {
        let key = StaticIdentity.generate().publicKey
        let a = try TrustStore(fileName: "devices.json")
        try a.add(publicKey: key, name: "one")
        a.touch(publicKey: key) // 2 回目以降の書き込み (置き換え)
        try a.add(publicKey: StaticIdentity.generate().publicKey, name: "two")
        let b = try TrustStore(fileName: "devices.json")
        XCTAssertEqual(b.all.count, 2)
        XCTAssertEqual(b.find(publicKey: key)?.name, "one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("devices.json.tmp").path))
        #if !os(Windows)
        let attrs = try FileManager.default.attributesOfItem(atPath: tmpDir.appendingPathComponent("devices.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #endif
    }

    func testIdentityIsPersisted() throws {
        let a = try SecretStore.loadOrCreateIdentity(name: "id")
        let b = try SecretStore.loadOrCreateIdentity(name: "id")
        XCTAssertEqual(a.publicKey, b.publicKey)
    }

    func testRateLimiterBacksOff() {
        let r = RateLimiter(freeFailures: 2, baseDelay: 10, maxDelay: 100)
        let t = Date()
        r.recordFailure("1.2.3.4", now: t)
        XCTAssertNil(r.blockedFor("1.2.3.4", now: t))
        r.recordFailure("1.2.3.4", now: t)
        XCTAssertEqual(r.blockedFor("1.2.3.4", now: t) ?? 0, 10, accuracy: 0.01)
        r.recordFailure("1.2.3.4", now: t)
        XCTAssertEqual(r.blockedFor("1.2.3.4", now: t) ?? 0, 20, accuracy: 0.01)
        XCTAssertNil(r.blockedFor("5.6.7.8", now: t))
        r.recordSuccess("1.2.3.4")
        XCTAssertNil(r.blockedFor("1.2.3.4", now: t))
    }

    func testAuthMessagesRejectGarbage() throws {
        let req = AuthRequest(deviceName: "Mac", pairingProof: [UInt8](repeating: 9, count: 32))
        XCTAssertEqual(try AuthRequest.decode(req.encode()), req)
        XCTAssertThrowsError(try AuthRequest.decode([0xFF, 0xFF]))
        var bad = AuthRequest(deviceName: "x", pairingProof: nil).encode()
        bad[bad.count - 1] = 5 // 証明長 5 は不正
        XCTAssertThrowsError(try AuthRequest.decode(bad))
        XCTAssertEqual(sanitize("a\u{1B}[31mb\nc"), "a?[31mb?c")
    }

    // MARK: 接続全体 (ループバック)

    private struct Env {
        let gate: HostGatekeeper
        let port: UInt16
        let hostIdentity: StaticIdentity
    }

    private func startHost(streaming: Bool = false) throws -> Env {
        let id = StaticIdentity.generate()
        let gate = HostGatekeeper(identity: id, clients: try TrustStore(fileName: "authorized_devices.json"),
                                  audit: AuditLog())
        gate.handshakeTimeout = 3
        let p = port()
        let listener = try TCPListener(port: p, bindAddress: "127.0.0.1")
        Thread {
            while true {
                guard let c = try? listener.accept() else { return }
                Thread {
                    guard let client = try? gate.authenticate(c) else { return }
                    // 認証できたら hello を送る (streaming なら、実際の画面配信のように切れるまで送り続ける)
                    repeat {
                        do {
                            try client.channel.send(.hello, Hello(width: 1, height: 1).encode())
                        } catch {
                            return
                        }
                    } while streaming
                }.start()
            }
        }.start()
        return Env(gate: gate, port: p, hostIdentity: id)
    }

    private func viewerConnect(_ env: Env, viewer: StaticIdentity, code: PairingCode?,
                               known: TrustStore) throws -> ViewerConnector.Session {
        try ViewerConnector.connect(host: "127.0.0.1", port: env.port, identity: viewer, knownHosts: known,
                                    pairingCode: code, deviceName: "test-mac")
    }

    func testEndToEndPairingThenReconnect() throws {
        let env = try startHost()
        let viewer = StaticIdentity.generate()
        let known = try TrustStore(fileName: "trusted_hosts.json")

        // 未登録ホスト + コードなし → ビューアが拒否 (TOFU しない)
        XCTAssertThrowsError(try viewerConnect(env, viewer: viewer, code: nil, known: known)) { e in
            guard case AuthError.unknownHost = e else { return XCTFail("\(e)") }
        }

        // 別ホスト用のコード → 指紋不一致で MITM として中止 (秘密は送らない)
        let foreign = PairingCode(hostPublicKey: StaticIdentity.generate().publicKey)
        XCTAssertThrowsError(try viewerConnect(env, viewer: viewer, code: foreign, known: known)) { e in
            guard case AuthError.hostKeyMismatch = e else { return XCTFail("\(e)") }
        }

        // ペアリング受付前 (コードの指紋部分は正しいが、ホストは受付中でない)
        let early = PairingCode(hostPublicKey: env.hostIdentity.publicKey)
        XCTAssertThrowsError(try viewerConnect(env, viewer: viewer, code: early, known: known)) { e in
            guard case AuthError.rejected(.pairingFailed, _) = e else { return XCTFail("\(e)") }
        }

        // ここまでの 3 回の失敗で 127.0.0.1 はブロックされている (総当たり対策が効いている)
        XCTAssertNotNil(env.gate.limiter.blockedFor("127.0.0.1"))
        env.gate.limiter.recordSuccess("127.0.0.1")

        // 正しいペアリング
        let window = env.gate.startPairing()
        let s = try viewerConnect(env, viewer: viewer, code: window.code, known: known)
        XCTAssertTrue(s.newlyPaired)
        XCTAssertEqual(s.hostPublicKey, env.hostIdentity.publicKey)
        let (t, _) = try s.channel.receive()
        XCTAssertEqual(t, MessageType.hello.rawValue)
        XCTAssertNotNil(env.gate.clients.find(publicKey: viewer.publicKey))
        s.channel.close()

        // 2 回目はコードなしで接続できる
        let s2 = try viewerConnect(env, viewer: viewer, code: nil, known: known)
        XCTAssertFalse(s2.newlyPaired)
        s2.channel.close()

        // 同じコードを別の端末が使っても使用済みで拒否
        let intruder = StaticIdentity.generate()
        let known2 = TrustStore.inMemoryForTesting()
        XCTAssertThrowsError(try viewerConnect(env, viewer: intruder, code: window.code, known: known2)) { e in
            guard case AuthError.rejected(.pairingFailed, _) = e else { return XCTFail("\(e)") }
        }

        // 未登録の端末 (ホストを知っていても) は拒否
        try known2.add(publicKey: env.hostIdentity.publicKey, name: "h")
        XCTAssertThrowsError(try viewerConnect(env, viewer: intruder, code: nil, known: known2)) { e in
            guard case AuthError.rejected(.unknownDevice, _) = e else { return XCTFail("\(e)") }
        }

        // 失効させると接続できない (別プロセスの RDHost --revoke と同じく、ディスク上の一覧だけを変更)
        let fp = Fingerprint.display(viewer.publicKey)
        let other = try TrustStore(fileName: "authorized_devices.json")
        XCTAssertEqual(try other.remove(matching: String(fp.prefix(9))), 1)
        XCTAssertFalse(env.gate.isStillAuthorized(viewer.publicKey))
        XCTAssertThrowsError(try viewerConnect(env, viewer: viewer, code: nil, known: known))
    }

    /// 回帰テスト: 接続を素早く繰り返しても、閉じたソケットの番号が再利用されて
    /// 前のセッションのデータが次の接続に混ざらないこと (use-after-close)
    func testRapidReconnectsDoNotCrossTalk() throws {
        let env = try startHost(streaming: true)
        let viewer = StaticIdentity.generate()
        let known = TrustStore.inMemoryForTesting()
        try env.gate.clients.add(publicKey: viewer.publicKey, name: "v")
        try known.add(publicKey: env.hostIdentity.publicKey, name: "h")
        for i in 0 ..< 60 {
            let s = try viewerConnect(env, viewer: viewer, code: nil, known: known)
            for _ in 0 ..< 3 {
                let (t, _) = try s.channel.receive() // 他のセッションのデータが混ざると復号に失敗して例外
                XCTAssertEqual(t, MessageType.hello.rawValue, "iteration \(i)")
            }
            s.channel.close()
        }
    }

    /// 中継サーバー (relay/server.js) を起動して、中継経由の接続全体を確かめる。Node が無ければ skip。
    func testRelayEndToEnd() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repo.appendingPathComponent("relay/server.js")
        #if os(Windows)
        let sep: Character = ";", exe = "node.exe"
        #else
        let sep: Character = ":", exe = "node"
        #endif
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? ProcessInfo.processInfo.environment["Path"] ?? "")
            .split(separator: sep).map(String.init) + ["/usr/local/bin", "/opt/homebrew/bin"]
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent("relay/node_modules/ws").path),
              let node = pathDirs.map({ URL(fileURLWithPath: $0).appendingPathComponent(exe).path })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("node または relay/node_modules が無いので skip")
        }
        let relayPort = port()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = [script.path]
        proc.environment = ["PORT": String(relayPort)]
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        defer { proc.terminate() }
        Thread.sleep(forTimeInterval: 0.7)
        let relayURL = URL(string: "ws://127.0.0.1:\(relayPort)")!

        let hostID = StaticIdentity.generate()
        let gate = HostGatekeeper(identity: hostID, clients: try TrustStore(fileName: "authorized_devices.json"),
                                  audit: AuditLog())
        let listener = RelayHostListener(relay: relayURL, hostPublicKey: hostID.publicKey) { _ in }
        defer { listener.stop() }
        Thread {
            listener.run { transport in
                guard let client = try? gate.authenticate(transport) else { return }
                while (try? client.channel.send(.hello, Hello(width: 1, height: 1).encode())) != nil {}
            }
        }.start()
        Thread.sleep(forTimeInterval: 0.7)

        let viewer = StaticIdentity.generate()
        let known = TrustStore.inMemoryForTesting()
        // 中継経由のペアリングは既定で拒否 (LAN 限定)
        let window = gate.startPairing()
        XCTAssertThrowsError(try ViewerConnector.connect(to: .relay(relayURL), identity: viewer, knownHosts: known,
                                                         pairingCode: window.code, deviceName: "v")) { e in
            guard case AuthError.rejected(.pairingFailed, _) = e else { return XCTFail("\(e)") }
        }
        gate.limiter.recordSuccess("relay:127.0.0.1")

        // 登録済みなら、保存したホスト鍵だけを頼りに何度でも接続できる (セッション間の混線もない)
        try gate.clients.add(publicKey: viewer.publicKey, name: "v")
        for i in 0 ..< 25 {
            let s = try ViewerConnector.connect(to: .relay(relayURL), identity: viewer, knownHosts: known,
                                                expectedHostKey: hostID.publicKey, pairingCode: nil, deviceName: "v")
            for _ in 0 ..< 3 {
                XCTAssertEqual(try s.channel.receive().type, MessageType.hello.rawValue, "iteration \(i)")
            }
            s.channel.close()
        }

        // 別のホスト鍵を期待して接続すると (部屋が違うので) つながらない
        XCTAssertThrowsError(try ViewerConnector.connect(to: .relay(relayURL), identity: viewer, knownHosts: known,
                                                         expectedHostKey: StaticIdentity.generate().publicKey,
                                                         pairingCode: nil, deviceName: "v"))
    }

    func testPairingIsLANOnlyByDefault() {
        XCTAssertTrue(isPrivateIPv4("192.168.1.20"))
        XCTAssertTrue(isPrivateIPv4("10.0.0.1"))
        XCTAssertTrue(isPrivateIPv4("172.20.3.4"))
        XCTAssertFalse(isPrivateIPv4("172.32.0.1"))
        XCTAssertFalse(isPrivateIPv4("8.8.8.8"))
        XCTAssertFalse(isPrivateIPv4("relay:1.2.3.4"))
        XCTAssertEqual(RelayRoom.id(hostPublicKey: [UInt8](repeating: 1, count: 32)).count, 26)
        let k = StaticIdentity.generate().publicKey
        let code = PairingCode(hostPublicKey: k)
        // ペアリングコードからもホスト鍵からも同じ部屋 ID になる
        XCTAssertEqual(RelayRoom.id(fingerprintPrefix: code.hostFingerprintPrefix), RelayRoom.id(hostPublicKey: k))
    }

    func testWrongPairingCodeIsRateLimited() throws {
        let env = try startHost()
        _ = env.gate.startPairing()
        let viewer = StaticIdentity.generate()
        let known = TrustStore.inMemoryForTesting()
        // 指紋部分は正しいが秘密が違うコード
        let wrong = PairingCode(hostPublicKey: env.hostIdentity.publicKey)
        for _ in 0 ..< 3 {
            XCTAssertThrowsError(try viewerConnect(env, viewer: viewer, code: wrong, known: known))
        }
        // 3 回失敗で IP がブロックされる (接続はすぐ切られる)
        XCTAssertNotNil(env.gate.limiter.blockedFor("127.0.0.1"))
        XCTAssertThrowsError(try viewerConnect(env, viewer: viewer, code: env.gate.currentPairing!.code, known: known))
    }

    func testGarbageBeforeHandshakeIsRejected() throws {
        let env = try startHost()
        let tcp = try TCPConnection.open(host: "127.0.0.1", port: env.port)
        tcp.setReceiveTimeout(5)
        try tcp.sendAll([0x00, 0x05, 1, 2, 3, 4, 5]) // 短すぎる Noise メッセージ
        XCTAssertThrowsError(try tcp.receive(exactly: 1)) // ホストが切断する
    }
}

extension TrustStore {
    /// テスト用: 一時ディレクトリ内の別ファイル
    static func inMemoryForTesting() -> TrustStore {
        try! TrustStore(fileName: "trust-\(UUID().uuidString).json")
    }
}
