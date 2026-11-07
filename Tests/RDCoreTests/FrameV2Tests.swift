import Foundation
import XCTest
@testable import RDCore

/// frame2 (通信量を減らす形式) のテスト
final class FrameV2Tests: XCTestCase {
    /// 文字や UI に近い画面: 白地に、少ない色の「文字」と帯
    private func uiImage(_ w: Int, _ h: Int, shift: Int = 0) -> [UInt8] {
        var img = [UInt8](repeating: 0xFF, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * 4
                let yy = y + shift
                if yy % 40 < 24 { // タイトルバー風の帯
                    img[i] = 0xD0; img[i + 1] = 0x80; img[i + 2] = 0x30
                } else if (yy % 18 < 12) && ((x / 3 + yy / 2) % 5 < 2) { // 文字風 (アンチエイリアスの中間色を少し)
                    let v: UInt8 = (x + yy) % 3 == 0 ? 0x60 : 0x20
                    img[i] = v; img[i + 1] = v; img[i + 2] = v
                }
            }
        }
        return img
    }

    /// 写真に近い画面: なめらかなグラデーション + ノイズ
    private func photoImage(_ w: Int, _ h: Int, shift: Int = 0, seed: UInt64 = 7) -> [UInt8] {
        var img = [UInt8](repeating: 0xFF, count: w * h * 4)
        var s = seed
        for y in 0 ..< h {
            for x in 0 ..< w {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let n = Int(s >> 61) // 0...7 のノイズ
                let i = (y * w + x) * 4
                let yy = y + shift
                img[i] = UInt8(truncatingIfNeeded: x / 3 + n)
                img[i + 1] = UInt8(truncatingIfNeeded: yy / 2 + n)
                img[i + 2] = UInt8(truncatingIfNeeded: (x + yy) / 5 + n)
            }
        }
        return img
    }

    private func encode(_ enc: FrameEncoder, _ img: [UInt8], _ w: Int, now: TimeInterval) -> [UInt8]? {
        img.withUnsafeBytes { enc.encode($0.baseAddress!, srcStride: w * 4, now: now) }
    }

    /// 動いている間は粗く送り、止まったら送り直して、最後はぴったり同じ画面になる
    func testMotionThenRefineIsExact() throws {
        let (w, h) = (330, 200)
        let enc = FrameEncoder(width: w, height: h)
        enc.format = .v2
        let fb = Framebuffer()
        fb.resize(width: w, height: h)

        var t: TimeInterval = 100
        for shift in 0 ..< 3 { // スクロール中
            let p = try XCTUnwrap(encode(enc, photoImage(w, h, shift: shift * 7), w, now: t))
            try fb.apply(p, format: .v2)
            t += 0.05
        }
        XCTAssertGreaterThan(enc.stats.lossyTiles, 0)
        XCTAssertTrue(enc.hasPendingRefine)
        let last = photoImage(w, h, shift: 14)
        XCTAssertNotEqual(fb.pixels, last) // まだ粗い

        // 止まって 0.3 秒たつまでは送り直さない
        XCTAssertNil(encode(enc, last, w, now: t + 0.1))
        // たったら 1 回だけ送り直す
        let refine = try XCTUnwrap(encode(enc, last, w, now: t + 0.4))
        try fb.apply(refine, format: .v2)
        XCTAssertEqual(fb.pixels, last)
        XCTAssertFalse(enc.hasPendingRefine)
        XCTAssertGreaterThan(enc.stats.refinedTiles, 0)
        // その後は何も送らない (静止ゼロ)
        XCTAssertNil(encode(enc, last, w, now: t + 5))
    }

    /// 文字を打つような小さな変化は、最初から可逆で送る (粗くしない)
    func testSmallChangeIsLossless() throws {
        let (w, h) = (256, 128)
        let enc = FrameEncoder(width: w, height: h)
        enc.format = .v2
        let fb = Framebuffer()
        fb.resize(width: w, height: h)
        var img = photoImage(w, h)
        // 最初の全画面は「動いている」扱い → 粗く → 送り直し
        try fb.apply(try XCTUnwrap(encode(enc, img, w, now: 0)), format: .v2)
        try fb.apply(try XCTUnwrap(encode(enc, img, w, now: 1)), format: .v2)
        XCTAssertEqual(fb.pixels, img)

        let lossyBefore = enc.stats.lossyTiles
        for k in 0 ..< 10 { img[(70 * w + 100 + k) * 4] ^= 0x5A } // 1 タイルの中だけ
        let p = try XCTUnwrap(encode(enc, img, w, now: 2))
        XCTAssertEqual(try fb.apply(p, format: .v2), 1)
        XCTAssertEqual(fb.pixels, img)
        XCTAssertEqual(enc.stats.lossyTiles, lossyBefore)
    }

    func testPaletteRoundTrip() throws {
        let w = 64, h = 64
        let img = uiImage(w, h)
        var px = [UInt32](repeating: 0, count: w * h)
        img.withUnsafeBytes { b in
            for i in 0 ..< w * h { px[i] = b.load(fromByteOffset: i * 4, as: UInt32.self) & 0x00FF_FFFF }
        }
        var out: [UInt8] = []
        XCTAssertTrue(px.withUnsafeBufferPointer { TilePalette.encode($0, into: &out) })
        var dst = [UInt8](repeating: 0, count: w * h * 4)
        try dst.withUnsafeMutableBytes { d in
            try out.withUnsafeBufferPointer { try TilePalette.decode($0, into: d.baseAddress!, stride: w * 4, width: w, height: h) }
        }
        XCTAssertEqual(dst, img)
        // 色が多すぎるタイルはパレットにしない
        let many = (0 ..< UInt32(4096)).map { $0 &* 977 }
        var o2: [UInt8] = []
        XCTAssertFalse(many.withUnsafeBufferPointer { TilePalette.encode($0, into: &o2) })
        XCTAssertTrue(o2.isEmpty)
    }

    func testCorruptV2IsRejected() {
        let fb = Framebuffer()
        fb.resize(width: 64, height: 64)
        // 不明な形式
        var w = ByteWriter()
        w.u32(1); w.u16(0); w.u16(0); w.u16(8); w.u16(8); w.u8(9); w.u32(0)
        XCTAssertThrowsError(try fb.apply(w.bytes, format: .v2))
        // パレットの範囲外の索引
        var p = ByteWriter()
        let data: [UInt8] = [0, 1, 2, 3, 0x80 | 63, 5] // 1 色、索引 5 を 64 個
        p.u32(1); p.u16(0); p.u16(0); p.u16(8); p.u16(8); p.u8(TileEncoding.palette.rawValue)
        p.u32(UInt32(data.count)); p.bytes += data
        XCTAssertThrowsError(try fb.apply(p.bytes, format: .v2))
        // 画素数が足りない HALF565
        var hfw = ByteWriter()
        hfw.u32(1); hfw.u16(0); hfw.u16(0); hfw.u16(8); hfw.u16(8); hfw.u8(TileEncoding.half565.rawValue)
        hfw.u32(3); hfw.bytes += [0x80, 0x12, 0x34] // 1 個だけ (16 個必要)
        XCTAssertThrowsError(try fb.apply(hfw.bytes, format: .v2))
    }

    func testCapabilitiesEventRoundTrip() throws {
        let (t, p) = ClientEvent.capabilities(ViewerCapability.frame2).encode()
        XCTAssertEqual(t, .capabilities)
        XCTAssertEqual(try ClientEvent.decode(type: t.rawValue, payload: p), .capabilities(ViewerCapability.frame2))
    }

    /// v1 と v2 のバイト数を、代表的な場面で比べる (数値はログに出す。削減していることだけを確かめる)
    func testV2SendsLessThanV1() throws {
        let (w, h) = (1280, 720)
        func run(_ format: FrameFormat, _ frames: [[UInt8]], settle: Bool) -> Int {
            let enc = FrameEncoder(width: w, height: h)
            enc.format = format
            var t: TimeInterval = 0
            for f in frames {
                _ = encode(enc, f, w, now: t)
                t += 0.1
            }
            if settle { _ = encode(enc, frames.last!, w, now: t + 1) } // 止まったあとの送り直しも数える
            return enc.stats.bytes
        }
        let scenes: [(String, [[UInt8]])] = [
            ("UI・文字の全画面", [uiImage(w, h)]),
            ("UI・文字のスクロール 10 回", (0 ..< 10).map { uiImage(w, h, shift: $0 * 9) }),
            ("写真の全画面", [photoImage(w, h)]),
            ("写真のスクロール 10 回", (0 ..< 10).map { photoImage(w, h, shift: $0 * 9) }),
        ]
        for (name, frames) in scenes {
            let v1 = run(.v1, frames, settle: false)
            let v2 = run(.v2, frames, settle: true)
            print(String(format: "[通信量] %@: v1 %d KB → v2 %d KB (%.0f%%)", name, v1 / 1024, v2 / 1024,
                         Double(v2) * 100 / Double(v1)))
            XCTAssertLessThan(v2, v1, name)
        }
    }
}
