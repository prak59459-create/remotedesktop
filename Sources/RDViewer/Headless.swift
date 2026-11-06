import Foundation
import RDCore

/// GUI なしで接続し、受信状況を表示する (動作確認用・Linux 用)
///   RDViewer --headless <host> [port] [--pair CODE] [--frames N] [--out screen.ppm]
///   RDViewer --headless --relay URL [--relay-transport auto|websocket|http] [--pair CODE | --host 指紋の先頭] [--frames N]
func runHeadless(_ arguments: [String]) -> Never {
    var positional: [String] = []
    var maxFrames = Int.max
    var outPath: String?
    var code: PairingCode?
    var relay: URL?
    var hostQuery: String?
    var it = arguments.makeIterator()
    while let a = it.next() {
        switch a {
        case "--headless": continue
        case "--frames": maxFrames = it.next().flatMap { Int($0) } ?? maxFrames
        case "--out": outPath = it.next()
        case "--data-dir": DataDirectory.overridePath = it.next()
        case "--relay": relay = it.next().flatMap(URL.init(string:))
        case "--host": hostQuery = it.next()
        case "--relay-transport":
            guard let m = it.next().flatMap(RelayTransportMode.init(rawValue:)) else {
                print("--relay-transport には auto / websocket / http のどれかを指定してください")
                exit(1)
            }
            RelayTransportMode.default = m
        case "--pair":
            guard let c = it.next().flatMap(PairingCode.parse) else {
                print("ペアリングコードの形式が正しくありません")
                exit(1)
            }
            code = c
        default: positional.append(a)
        }
    }
    let client: ViewerClient
    if let relay = relay {
        // 中継: 初回はペアリングコードから、2 回目以降は保存済みホストの鍵から部屋を決める
        var key: [UInt8]?
        if code == nil {
            let hosts = (try? TrustStore(fileName: "trusted_hosts.json"))?.all ?? []
            let q = (hostQuery ?? "").uppercased().replacingOccurrences(of: "-", with: "")
            let matches = hosts.filter { e in
                guard let k = Fingerprint.fromHex(e.publicKey) else { return false }
                return q.isEmpty || Fingerprint.display(k).replacingOccurrences(of: "-", with: "").hasPrefix(q)
            }
            guard matches.count == 1, let k = Fingerprint.fromHex(matches[0].publicKey) else {
                print(matches.isEmpty ? "信頼済みのホストがありません。--pair でペアリングしてください"
                                      : "ホストが複数あります。--host で指紋の先頭を指定してください")
                exit(1)
            }
            key = k
        }
        client = ViewerClient(endpoint: .relay(relay), expectedHostKey: key, pairingCode: code)
    } else {
        guard let host = positional.first else {
            print("使い方: RDViewer --headless <host> [port] [--pair CODE] [--frames N] [--out screen.ppm]")
            print("       RDViewer --headless --relay URL [--pair CODE | --host 指紋] [--frames N]")
            exit(1)
        }
        let port = positional.count > 1 ? UInt16(positional[1]) ?? defaultPort : defaultPort
        client = ViewerClient(host: host, port: port, pairingCode: code)
    }
    let done = DispatchSemaphore(value: 0)
    let start = Date()
    client.onHello = { w, h in print("hello: \(w)x\(h)") }
    client.onFrame = { _ in
        let n = client.framesReceived
        if n == 1 {
            // 入力の送信テスト
            client.send(.mouseMove(x: 10, y: 20))
            client.send(.mouseButton(.left, down: true))
            client.send(.mouseButton(.left, down: false))
            client.send(.mouseWheel(dx: 0, dy: 120))
            client.send(.key(code: 0x1E, down: true, virtualKey: false))
            client.send(.key(code: 0x1E, down: false, virtualKey: false))
            client.send(.text("こんにちは"))
        }
        if n % 30 == 0 || n == maxFrames {
            let t = Date().timeIntervalSince(start)
            print(String(format: "frames=%d  %.1f fps  %.1f KB/s", n, Double(n) / t,
                         Double(client.bytesReceived) / t / 1024))
        }
        if n >= maxFrames { done.signal() }
    }
    client.onClose = { err in
        print("切断されました\(err.map { ": \($0)" } ?? "")")
        done.signal()
    }
    do {
        try client.connect()
    } catch {
        print("エラー: \(error)")
        exit(1)
    }
    if let s = client.session {
        print("接続しました (暗号化・相互認証済み): \(client.label)  ホストの指紋: \(s.hostFingerprint)\(s.newlyPaired ? "  [新規ペアリング]" : "")")
    }
    done.wait()
    if let path = outPath { writePPM(client.framebuffer, to: path) }
    client.disconnect()
    exit(0)
}

private func writePPM(_ fb: Framebuffer, to path: String) {
    var data = Data("P6\n\(fb.width) \(fb.height)\n255\n".utf8)
    data.reserveCapacity(data.count + fb.width * fb.height * 3)
    let px = fb.pixels
    var i = 0
    while i < px.count {
        data.append(px[i + 2]); data.append(px[i + 1]); data.append(px[i])
        i += 4
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("保存しました: \(path)")
    } catch {
        print("保存に失敗: \(error)")
    }
}
