import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// ホストとの接続状態と、受信した画面を管理する
final class ViewerSession: ObservableObject {
    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
    }

    @Published var phase: Phase = .idle
    @Published var alert: AlertItem?
    @Published var hostFingerprint = ""
    @Published var securitySummary = ""
    @Published var remoteSize = CGSize.zero
    @Published var commandAsControl = UserDefaults.standard.object(forKey: "cmdAsCtrl") as? Bool ?? true {
        didSet { UserDefaults.standard.set(commandAsControl, forKey: "cmdAsCtrl") }
    }

    var isShowingScreen: Bool { phase == .connected }

    /// 通信状況 (1 秒ごとに更新)
    struct Stats: Equatable {
        var fps = 0
        var kbps = 0.0
        var totalBytes = 0
    }

    @Published var stats = Stats()
    private let statsLock = NSLock()
    private var frameCount = 0
    private var byteCount = 0
    private var totalBytes = 0
    private var statsTimer: Timer?
    private var latestImage: CGImage?

    /// 最後に受け取った画面 (スクリーンショット用)
    var lastImage: CGImage? {
        statsLock.lock(); defer { statsLock.unlock() }
        return latestImage
    }

    private func startStats() {
        statsLock.lock(); frameCount = 0; byteCount = 0; totalBytes = 0; statsLock.unlock()
        stats = Stats()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.statsLock.lock()
            let s = Stats(fps: self.frameCount, kbps: Double(self.byteCount) * 8 / 1000, totalBytes: self.totalBytes)
            self.frameCount = 0
            self.byteCount = 0
            self.statsLock.unlock()
            if s != self.stats { self.stats = s }
        }
    }

    private func stopStats() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    /// 受信スレッドから呼ばれる (画面の更新)
    var onImage: ((CGImage) -> Void)?

    private var channel: MessageChannel?
    private let framebuffer = Framebuffer()
    private let sendQueue = DispatchQueue(label: "rd.send")

    // MARK: 保存済み設定

    /// ペアリングした PC の公開鍵。アプリを入れ直す (更新する) と UserDefaults は消えるので、キーチェーンにも置く
    static var savedHostKey: [UInt8]? {
        get {
            if let k = UserDefaults.standard.string(forKey: "hostKey").flatMap(Fingerprint.fromHex) { return k }
            guard let k = (try? SecretStore.load(name: "paired_host_key")) ?? nil, k.count == 32 else { return nil }
            UserDefaults.standard.set(Fingerprint.hex(k), forKey: "hostKey")
            return k
        }
        set {
            UserDefaults.standard.set(newValue.map(Fingerprint.hex), forKey: "hostKey")
            if let k = newValue {
                try? SecretStore.save(name: "paired_host_key", bytes: k)
            } else {
                try? SecretStore.delete(name: "paired_host_key")
            }
        }
    }

    static var savedHostFingerprint: String? { savedHostKey.map(Fingerprint.display) }

    // MARK: 接続

    func connect(endpoint: ViewerConnector.Endpoint, pairingCode: PairingCode?) {
        guard phase == .idle else { return }
        phase = .connecting
        // 中継経由やコードなしの直接接続では、保存したホスト鍵と完全一致を要求する
        let expected = pairingCode == nil ? Self.savedHostKey : nil
        if pairingCode == nil && expected == nil {
            phase = .idle
            alert = AlertItem(title: "まだペアリングしていません",
                              message: "最初は Windows と同じ Wi-Fi で、PC の IP アドレスとペアリングコードを入力して接続してください。")
            return
        }
        Thread { [weak self] in
            do {
                // 端末鍵は Secure Enclave で包んであり、取り出すたびに Face ID が必要 (紛失・盗難対策)
                let (identity, level) = try DeviceKeyProtection.loadOrCreateIdentity(
                    name: "viewer_identity_v2", reason: "Windows PC に接続します")
                let known = try TrustStore(fileName: "trusted_hosts.json")
                let s = try ViewerConnector.connect(to: endpoint, identity: identity, knownHosts: known,
                                                    expectedHostKey: expected, pairingCode: pairingCode,
                                                    deviceName: UIDevice.current.name)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    Self.savedHostKey = s.hostPublicKey
                    self.channel = s.channel
                    self.hostFingerprint = s.hostFingerprint
                    self.securitySummary = "\(s.isPostQuantum ? "耐量子暗号 (ML-KEM) + " : "")端末鍵: \(level.rawValue)"
                    self.phase = .connected
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastConnected")
                    self.startStats()
                    if s.newlyPaired {
                        self.alert = AlertItem(
                            title: "ペアリングしました",
                            message: "ホストの指紋:\n\(s.hostFingerprint)\n\nWindows の画面に表示されている指紋と同じか確認してください。次回からはコードなしで接続でき、外出先からは中継経由で接続できます。\n\n\(self.securitySummary)")
                    }
                }
                self?.receiveLoop(s.channel)
            } catch {
                DispatchQueue.main.async {
                    self?.phase = .idle
                    self?.alert = AlertItem(title: "接続できませんでした", message: "\(error)")
                }
            }
        }.start()
    }

    /// 端末の鍵と保存したホストを消す (次の接続で新しい鍵を作るので、ペアリングし直しが必要)
    func resetDeviceKey() {
        do {
            try DeviceKeyProtection.reset(name: "viewer_identity_v2")
            Self.savedHostKey = nil
            alert = AlertItem(title: "端末の鍵をリセットしました",
                              message: "同じ Wi-Fi で、ペアリングコードを使ってもう一度接続してください。")
        } catch {
            alert = AlertItem(title: "リセットできませんでした", message: "\(error)")
        }
    }

    func disconnect() {
        channel?.close()
        channel = nil
        stopStats()
        phase = .idle
    }

    func send(_ event: ClientEvent) {
        guard let ch = channel else { return }
        sendQueue.async { try? ch.send(event) }
    }

    private func receiveLoop(_ ch: MessageChannel) {
        var reason: String?
        do {
            while true {
                let (type, payload) = try ch.receive()
                statsLock.lock(); byteCount += payload.count + 5; totalBytes += payload.count + 5; statsLock.unlock()
                switch MessageType(rawValue: type) {
                case .hello:
                    let h = try Hello.decode(payload)
                    framebuffer.resize(width: h.width, height: h.height)
                    DispatchQueue.main.async { self.remoteSize = CGSize(width: h.width, height: h.height) }
                    // 通信量の少ない形式を受け取れることを伝える (古いホストは無視する)
                    try ch.send(.capabilities(ViewerCapability.frame2))
                case .frame, .frame2:
                    try framebuffer.apply(payload, format: type == MessageType.frame2.rawValue ? .v2 : .v1)
                    try ch.send(.frameAck)
                    if let img = makeImage(framebuffer) {
                        statsLock.lock(); frameCount += 1; latestImage = img; statsLock.unlock()
                        onImage?(img)
                    }
                default:
                    break
                }
            }
        } catch NetError.closed {
            reason = nil
        } catch {
            reason = "\(error)"
        }
        ch.close()
        DispatchQueue.main.async {
            guard self.channel === ch else { return } // 自分で切断した場合
            self.channel = nil
            self.stopStats()
            self.phase = .idle
            self.alert = AlertItem(title: "接続が終了しました", message: reason ?? "ホスト側で切断されました。")
        }
    }
}

func makeImage(_ fb: Framebuffer) -> CGImage? {
    guard fb.width > 0, fb.height > 0 else { return nil }
    let data = fb.pixels.withUnsafeBytes { CFDataCreate(nil, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    guard let d = data, let provider = CGDataProvider(data: d) else { return nil }
    // メモリ上 B,G,R,A = 32bit リトルエンディアンの ARGB
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(width: fb.width, height: fb.height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: fb.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}
