import Foundation
import XCTest
@testable import RDCore

final class RDCoreTests: XCTestCase {
    private func randomImage(_ w: Int, _ h: Int, seed: UInt64) -> [UInt8] {
        var s = seed
        var img = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: img.count, by: 4) {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            // ランダムな部分と単色の部分を混ぜる
            let v = (i / 4) % 7 < 3 ? UInt8(truncatingIfNeeded: s >> 33) : 0x40
            img[i] = v; img[i + 1] = v &+ 1; img[i + 2] = v &+ 2; img[i + 3] = 0xFF
        }
        return img
    }

    func testFrameRoundTrip() throws {
        let (w, h) = (200, 130) // タイルサイズで割り切れないサイズ
        let enc = FrameEncoder(width: w, height: h)
        let fb = Framebuffer()
        fb.resize(width: w, height: h)

        var img = randomImage(w, h, seed: 1)
        let p1 = try XCTUnwrap(img.withUnsafeBytes { enc.encode($0.baseAddress!, srcStride: w * 4) })
        XCTAssertEqual(try fb.apply(p1), 4 * 3)
        XCTAssertEqual(fb.pixels, img)

        // 変化なし → nil
        XCTAssertNil(img.withUnsafeBytes { enc.encode($0.baseAddress!, srcStride: w * 4) })

        // 1 画素だけ変更 → 1 タイル
        img[(100 * w + 150) * 4] = 0x12
        let p2 = try XCTUnwrap(img.withUnsafeBytes { enc.encode($0.baseAddress!, srcStride: w * 4) })
        XCTAssertEqual(try fb.apply(p2), 1)
        XCTAssertEqual(fb.pixels, img)
    }

    func testRLECompressesSolidColor() {
        let px = [UInt32](repeating: 0x00AB_CDEF, count: 64 * 64)
        var out: [UInt8] = []
        px.withUnsafeBufferPointer { TileRLE.encode($0, into: &out) }
        XCTAssertEqual(out.count, 32 * 4) // 128 画素ごとに 4 バイト
    }

    func testClientEventRoundTrip() throws {
        let events: [ClientEvent] = [
            .frameAck, .requestKeyframe, .mouseMove(x: -5, y: 1080),
            .mouseButton(.x2, down: true), .mouseWheel(dx: -120, dy: 360),
            .key(code: 0xE04B, down: false, virtualKey: false), .key(code: 0x16, down: true, virtualKey: true),
        ]
        for e in events {
            let (t, p) = e.encode()
            XCTAssertEqual(try ClientEvent.decode(type: t.rawValue, payload: p), e)
        }
    }

    func testCorruptTileIsRejected() {
        let fb = Framebuffer()
        fb.resize(width: 64, height: 64)
        var w = ByteWriter()
        w.u32(1); w.u16(32); w.u16(32); w.u16(64); w.u16(64); w.u32(0) // 画面外
        XCTAssertThrowsError(try fb.apply(w.bytes))
    }

    func testLoopbackSocket() throws {
        let listener = try TCPListener(port: 47123)
        let done = expectation(description: "recv")
        Thread {
            let c = try! listener.accept()
            let ch = MessageChannel(c)
            let (t, p) = try! ch.receive()
            XCTAssertEqual(t, MessageType.mouseMove.rawValue)
            XCTAssertEqual(try! ClientEvent.decode(type: t, payload: p), .mouseMove(x: 3, y: 4))
            done.fulfill()
        }.start()
        let ch = MessageChannel(try TCPConnection.open(host: "127.0.0.1", port: 47123))
        try ch.send(.mouseMove(x: 3, y: 4))
        wait(for: [done], timeout: 5)
    }
}
