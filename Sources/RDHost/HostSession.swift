import Dispatch
import Foundation
import RDCore

struct HostOptions {
    var port: UInt16 = defaultPort
    var bindAddress: String?
    var fps: Double = 30
    var scale: Int = 1
    var pair = false
    var confirm = false
    var relay: URL?
    var direct = true
    var allowRemotePairing = false
}

/// 認証済みの 1 つのビューア接続を担当する。画面送信ループと入力受信スレッドを持つ。
final class HostSession {
    private let channel: MessageChannel
    private let client: HostGatekeeper.Client
    private let audit: AuditLog
    private let options: HostOptions
    private let injector = makeInjector()
    private let ackSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var closed = false
    private var keyframeRequested = false
    // 入力座標の変換用 (フレーム座標 → 実画面座標)
    private var mapping = (frameW: 1, frameH: 1, screenW: 1, screenH: 1)

    private let gate: HostGatekeeper

    init(client: HostGatekeeper.Client, gate: HostGatekeeper, options: HostOptions, audit: AuditLog) {
        self.client = client
        self.gate = gate
        channel = client.channel
        self.options = options
        self.audit = audit
    }

    private var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    private func markClosed() {
        stateLock.lock()
        closed = true
        stateLock.unlock()
        channel.close()
        ackSemaphore.signal()
    }

    private func takeKeyframeRequest() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        let r = keyframeRequested
        keyframeRequested = false
        return r
    }

    func run() {
        let receiver = Thread { [self] in receiveLoop() }
        receiver.start()
        sendLoop()
        markClosed()
        audit.record("SESSION_END name=\(client.name) peer=\(client.peer)")
    }

    // MARK: 画面送信

    private func sendLoop() {
        let interval = 1.0 / max(1, options.fps)
        var lastAuthCheck = Date()
        while !isClosed {
            guard let capturer = makeCapturer(scale: options.scale) else {
                print("画面キャプチャを初期化できません。1 秒後に再試行します")
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            stateLock.lock()
            mapping = (capturer.width, capturer.height, capturer.screenWidth, capturer.screenHeight)
            stateLock.unlock()
            print("画面 \(capturer.screenWidth)x\(capturer.screenHeight) → 送信 \(capturer.width)x\(capturer.height)")

            do {
                try channel.send(.hello, Hello(width: capturer.width, height: capturer.height).encode())
            } catch {
                return
            }
            let encoder = FrameEncoder(width: capturer.width, height: capturer.height)

            while !isClosed {
                let start = Date()
                if start.timeIntervalSince(lastAuthCheck) > 2 {
                    lastAuthCheck = start
                    if !gate.isStillAuthorized(client.publicKey) {
                        audit.record("SESSION_KILLED reason=device_revoked name=\(client.name) peer=\(client.peer)")
                        return
                    }
                }
                if capturer.needsRecreate { break } // 解像度変更 → hello から送り直す
                if takeKeyframeRequest() { encoder.reset() }

                if let image = capturer.capture(),
                   let payload = encoder.encode(image, srcStride: capturer.bytesPerRow) {
                    do {
                        try channel.send(.frame, payload)
                    } catch {
                        return
                    }
                    // ビューアが処理し終えるまで次を送らない (遅い回線で溜まらないように)
                    _ = ackSemaphore.wait(timeout: .now() + 5)
                }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < interval { Thread.sleep(forTimeInterval: interval - elapsed) }
            }
        }
    }

    // MARK: 入力受信

    private func receiveLoop() {
        defer { markClosed() }
        do {
            while true {
                let (type, payload) = try channel.receive()
                guard let event = try ClientEvent.decode(type: type, payload: payload) else { continue }
                handle(event)
            }
        } catch {
            // 切断
        }
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .frameAck:
            ackSemaphore.signal()
        case .requestKeyframe:
            stateLock.lock()
            keyframeRequested = true
            stateLock.unlock()
        case let .mouseMove(x, y):
            stateLock.lock()
            let m = mapping
            stateLock.unlock()
            let fx = min(max(Int(x), 0), m.frameW - 1)
            let fy = min(max(Int(y), 0), m.frameH - 1)
            injector.moveMouse(x: fx * m.screenW / m.frameW, y: fy * m.screenH / m.frameH)
        case let .mouseButton(button, down):
            injector.mouseButton(Int(button.rawValue), down: down)
        case let .mouseWheel(dx, dy):
            injector.wheel(dx: dx, dy: dy)
        case let .key(code, down, vk):
            injector.key(code: code, down: down, virtualKey: vk)
        case let .text(s):
            injector.text(s)
        }
    }
}
