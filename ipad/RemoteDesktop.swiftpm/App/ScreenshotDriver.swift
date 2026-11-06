#if RD_SCREENSHOTS
// スクリーンショット撮影用の自動操作 (CI の ipad-screenshots ワークフロー専用)。
// xcodebuild に OTHER_SWIFT_FLAGS=-DRD_SCREENSHOTS を渡したときだけコンパイルされ、
// 通常のビルド (Swift Playgrounds / Xcode) には含まれない。
// ユーザーが画面で行う操作 (入力・ボタン) をなぞるだけで、ペアリングやホスト側の許可は省略しない。
//
// 撮影の合図: アプリが Documents/shots/<名前>.ready を作る → CI が撮影して <名前>.done を作る → 次へ進む
import Combine
import SwiftUI
import UIKit

final class ScreenshotDriver: ObservableObject {
    static let shared = ScreenshotDriver()

    let pairingCode = PassthroughSubject<String, Never>()
    let pressConnect = PassthroughSubject<Void, Never>()
    let showTextSheet = PassthroughSubject<String, Never>()
    let toggleKeyboard = PassthroughSubject<Void, Never>()

    private var started = false
    private let env = ProcessInfo.processInfo.environment
    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("shots")

    @MainActor func start(session: ViewerSession) {
        guard !started, env["RD_SHOT_HOST"] != nil else { return }
        started = true
        Task { await run(session) }
    }

    @MainActor private func run(_ session: ViewerSession) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let relay = env["RD_SHOT_RELAY"] ?? "https://xxxx.onrender.com"

        // 1. 起動直後 (同じ Wi-Fi)
        d.set("同じ Wi-Fi", forKey: "mode")
        d.set("", forKey: "lanHost")
        d.set("", forKey: "lanService")
        d.set("5999", forKey: "lanPort")
        // Bonjour でホストが見つかるのを待つ (見つかった一覧が画面に出る)
        let finder = HostBrowser()
        var found: [String] = []
        finder.onChange = { found = $0 }
        finder.start()
        _ = await until(20) { !found.isEmpty }
        finder.stop()
        await wait(1)
        await shot("01-connect-empty")

        // 2. 外出先 (中継) に切り替え
        d.set("外出先 (中継)", forKey: "mode")
        d.set(relay, forKey: "relayURL")
        await wait(1)
        await shot("02-connect-relay")

        // 3. まだペアリングしていないのに中継で接続しようとしたとき
        pressConnect.send()
        await wait(1)
        await shot("03-error-not-paired")
        session.alert = nil
        await wait(1)

        // 4. 同じ Wi-Fi で IP とペアリングコードを入力
        d.set("同じ Wi-Fi", forKey: "mode")
        if let name = found.first {
            // 見つかった PC を選ぶ (Bonjour で名前を使って接続する)
            d.set("", forKey: "lanHost")
            d.set(name, forKey: "lanService")
            try? Data(name.utf8).write(to: dir.appendingPathComponent("used-bonjour"))
        } else {
            d.set(env["RD_SHOT_HOST"] ?? "", forKey: "lanHost")
        }
        d.set(env["RD_SHOT_PORT"] ?? "5999", forKey: "lanPort")
        await wait(1)
        pairingCode.send(env["RD_SHOT_CODE"] ?? "")
        await wait(1)
        await shot("04-connect-filled")

        // 5. 接続 → 本人確認 (CI が撮影後に Face ID の「一致」を送る) → ペアリング完了のお知らせ
        pressConnect.send()
        await wait(2.5)
        await shot("05-auth")
        guard await until(30, { session.phase == .connected }) else {
            await wait(1)
            await shot("99-connect-failed")
            try? Data().write(to: dir.appendingPathComponent("finished"))
            return
        }
        setOrientation(.landscapeRight)
        await wait(3)
        await shot("06-paired")
        session.alert = nil
        await wait(2)

        // 6. リモート画面 (横向き)
        await shot("07-remote-landscape")

        // 7. 入力が届くことの確認用に、マウスとキーを少し送る
        session.send(.mouseMove(x: 320, y: 200))
        session.send(.mouseButton(.left, down: true))
        session.send(.mouseButton(.left, down: false))
        session.send(.mouseWheel(dx: 0, dy: -120))

        // 8. 画面キーボード
        toggleKeyboard.send()
        await wait(2)
        await shot("08-remote-keyboard")
        toggleKeyboard.send()
        await wait(1)

        // 9. 日本語の文字入力
        showTextSheet.send("こんにちは、リモートデスクトップ")
        await wait(2)
        await shot("09-text-input")
        session.send(.text("こんにちは"))
        showTextSheet.send("")
        await wait(1)

        // 10. 縦向き
        setOrientation(.portrait)
        await wait(3)
        await shot("10-remote-portrait")

        // 11. 切断後 (ペアリング済みのホストが表示される)
        session.disconnect()
        await wait(2)
        await shot("11-after-disconnect")

        // 12. 2 回目以降: コードなしで接続 (端末鍵を取り出すたびに本人確認)
        pressConnect.send()
        await wait(2.5)
        await shot("12-reconnect-auth")
        if await until(30, { session.phase == .connected }) {
            await wait(3)
            await shot("13-reconnected")
            session.disconnect()
        }

        // 14. 外出先 (中継サーバー経由) で接続 (RD_SHOT_RELAY_REAL があるときだけ。実際の中継サーバーを使う)
        if let real = env["RD_SHOT_RELAY_REAL"], !real.isEmpty {
            await wait(2)
            d.set("外出先 (中継)", forKey: "mode")
            d.set(real, forKey: "relayURL")
            await wait(1)
            pressConnect.send()
            await wait(2.5)
            await shot("14-relay-auth")
            if await until(60, { session.phase == .connected }) {
                await wait(3)
                await shot("15-relay-connected")
                try? Data().write(to: dir.appendingPathComponent("relay-ok"))
                session.disconnect()
            } else {
                await wait(1)
                await shot("15-relay-failed")
            }
        }

        try? Data().write(to: dir.appendingPathComponent("finished"))
    }

    @MainActor private func setOrientation(_ o: UIInterfaceOrientationMask) {
        guard #available(iOS 16.0, *),
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: o)) { _ in }
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func until(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await wait(0.2)
        }
        return cond()
    }

    /// CI に撮影を頼み、撮り終わるまで待つ (最大 60 秒)
    private func shot(_ name: String) async {
        let fm = FileManager.default
        fm.createFile(atPath: dir.appendingPathComponent(name + ".ready").path, contents: nil)
        let done = dir.appendingPathComponent(name + ".done").path
        _ = await until(60) { fm.fileExists(atPath: done) }
    }
}
#endif
