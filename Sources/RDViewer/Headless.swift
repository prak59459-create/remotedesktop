import Foundation
import RDCore

/// GUI なしで接続し、受信状況を表示する (動作確認用・Linux 用)
///   RDViewer --headless <host> [port] [--pair CODE] [--frames N] [--out screen.ppm]
func runHeadless(_ arguments: [String]) -> Never {
    var positional: [String] = []
    var maxFrames = Int.max
    var outPath: String?
    var code: PairingCode?
    var it = arguments.makeIterator()
    while let a = it.next() {
        switch a {
        case "--headless": continue
        case "--frames": maxFrames = it.next().flatMap { Int($0) } ?? maxFrames
        case "--out": outPath = it.next()
        case "--data-dir": DataDirectory.overridePath = it.next()
        case "--pair":
            guard let c = it.next().flatMap(PairingCode.parse) else {
                print("ペアリングコードの形式が正しくありません")
                exit(1)
            }
            code = c
        default: positional.append(a)
        }
    }
    guard let host = positional.first else {
        print("使い方: RDViewer --headless <host> [port] [--pair CODE] [--frames N] [--out screen.ppm]")
        exit(1)
    }
    let port = positional.count > 1 ? UInt16(positional[1]) ?? defaultPort : defaultPort

    let client = ViewerClient(host: host, port: port, pairingCode: code)
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
        print("接続しました (暗号化・相互認証済み): \(host):\(port)  ホストの指紋: \(s.hostFingerprint)\(s.newlyPaired ? "  [新規ペアリング]" : "")")
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
