#if !os(Windows)
import Foundation
import RDCore

// Windows 以外で RDHost を動かしたとき用 (開発・動作確認用)。
// 動くテストパターンを配信し、受け取った入力はログに出す。

final class TestPatternCapturer: ScreenCapturer {
    let width: Int
    let height: Int
    var screenWidth: Int { width }
    var screenHeight: Int { height }
    var bytesPerRow: Int { width * 4 }
    var needsRecreate: Bool { false }

    private let pixels: UnsafeMutablePointer<UInt32>
    private var frame = 0

    init(scale: Int) {
        width = 1280 / max(1, scale)
        height = 720 / max(1, scale)
        pixels = .allocate(capacity: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width { pixels[y * width + x] = background(x, y) }
        }
    }

    deinit { pixels.deallocate() }

    private func background(_ x: Int, _ y: Int) -> UInt32 {
        let r = UInt32(x * 255 / width), g = UInt32(y * 255 / height)
        return 0xFF00_0000 | r << 16 | g << 8 | 0x60
    }

    func capture() -> UnsafeRawPointer? {
        frame += 1
        let box = max(8, width / 16)
        let x0 = (frame * 7) % max(1, width - box)
        let y0 = height / 2 - box / 2
        // 移動する白い四角 (前の位置はグラデーションに戻す)
        for y in y0 ..< y0 + box {
            for x in 0 ..< width {
                pixels[y * width + x] = (x >= x0 && x < x0 + box) ? 0xFFFF_FFFF : background(x, y)
            }
        }
        return UnsafeRawPointer(pixels)
    }
}

final class LoggingInputInjector: InputInjector {
    func text(_ s: String) { print("[input] text \"\(sanitize(s))\"") }
    func moveMouse(x: Int, y: Int) { print("[input] move \(x),\(y)") }
    func mouseButton(_ button: Int, down: Bool) { print("[input] button \(button) \(down ? "down" : "up")") }
    func wheel(dx: Int32, dy: Int32) { print("[input] wheel dx=\(dx) dy=\(dy)") }
    func key(code: UInt16, down: Bool, virtualKey: Bool) {
        print("[input] key \(virtualKey ? "vk" : "sc")=0x\(String(code, radix: 16)) \(down ? "down" : "up")")
    }
}

/// 端末で接続を許可するか確認する
func askConsent(name: String, fingerprint: String, peer: String, isNew: Bool) -> Bool {
    print("\n\(isNew ? "新しい端末" : "端末") 「\(name)」 (\(fingerprint)) が \(peer) から接続を求めています。許可しますか? [y/N] ", terminator: "")
    return readLine()?.lowercased() == "y"
}

func makeCapturer(scale: Int) -> ScreenCapturer? { TestPatternCapturer(scale: scale) }
func makeInjector() -> InputInjector { LoggingInputInjector() }
func platformSetup() {
    print("※ Windows 以外なのでテストパターンを配信します (入力はログ出力のみ)")
}
#endif
