// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/TileCodec.swift からコピー。直接編集しないでください。
import Foundation

// 画面は 32bit BGRA (メモリ上のバイト順 B,G,R,A) として扱う。
// 画面を tileSize 四方のタイルに分割し、前回送ったフレームから変化したタイルだけを
// 簡易 RLE (24bit 色) で圧縮して送る。
//
// frame payload:
//   tileCount u32
//   tile * tileCount:
//     x u16, y u16, w u16, h u16, dataLength u32, data
//
// tile data (RLE): 制御バイト c の後に
//   c & 0x80 != 0 : 同じ色が (c & 0x7F) + 1 個続く。色 3 バイト (B,G,R) が 1 つ
//   c & 0x80 == 0 : 異なる色が c + 1 個。色 3 バイトがその個数分

public enum TileRLE {
    /// pixels (0x00RRGGBB の配列) を RLE 圧縮して out に追記する
    public static func encode(_ pixels: UnsafeBufferPointer<UInt32>, into out: inout [UInt8]) {
        let n = pixels.count
        var i = 0
        @inline(__always) func put(_ p: UInt32) {
            out.append(UInt8(truncatingIfNeeded: p))
            out.append(UInt8(truncatingIfNeeded: p >> 8))
            out.append(UInt8(truncatingIfNeeded: p >> 16))
        }
        while i < n {
            let p = pixels[i]
            var run = 1
            while i + run < n, run < 128, pixels[i + run] == p { run += 1 }
            if run >= 2 {
                out.append(0x80 | UInt8(run - 1))
                put(p)
                i += run
                continue
            }
            // リテラル: 次に同色が 2 つ続く位置の手前まで
            let start = i
            var lit = 1
            i += 1
            while i < n, lit < 128 {
                if i + 1 < n, pixels[i] == pixels[i + 1] { break }
                lit += 1
                i += 1
            }
            out.append(UInt8(lit - 1))
            for k in start ..< start + lit { put(pixels[k]) }
        }
    }

    /// RLE を展開して BGRA の矩形 (dst から stride 間隔の行) へ書き込む
    public static func decode(
        _ data: UnsafeBufferPointer<UInt8>,
        into dst: UnsafeMutableRawPointer, stride: Int, width w: Int, height h: Int
    ) throws {
        let total = w * h
        var written = 0
        var col = 0
        var row = dst.assumingMemoryBound(to: UInt32.self)
        var i = 0
        let n = data.count

        @inline(__always) func emit(_ v: UInt32) {
            row[col] = v
            col += 1
            if col == w {
                col = 0
                row = (UnsafeMutableRawPointer(row) + stride).assumingMemoryBound(to: UInt32.self)
            }
        }

        while i < n {
            let c = data[i]
            i += 1
            let count = Int(c & 0x7F) + 1
            guard written + count <= total else { throw ProtocolError.invalid("タイルの画素数が多すぎます") }
            if c & 0x80 != 0 {
                guard i + 3 <= n else { throw ProtocolError.truncated }
                let v = 0xFF00_0000 | UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16
                i += 3
                for _ in 0 ..< count { emit(v) }
            } else {
                guard i + 3 * count <= n else { throw ProtocolError.truncated }
                for _ in 0 ..< count {
                    emit(0xFF00_0000 | UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16)
                    i += 3
                }
            }
            written += count
        }
        guard written == total else { throw ProtocolError.invalid("タイルの画素数が足りません (\(written)/\(total))") }
    }
}

/// ホスト側: キャプチャした画面から差分フレームを作る
public final class FrameEncoder {
    public let width: Int
    public let height: Int
    public let tileSize: Int
    private var previous: [UInt8]
    private var hasPrevious = false
    private var scratch: [UInt32]

    /// v1 = 従来の RLE だけ (古いビューア向け)。v2 = パレット・動き中の粗い画質・静止後の高画質化
    public var format: FrameFormat = .v1
    /// 粗く送ったタイルが、この時間変化しなければ可逆で送り直す
    public var refineDelay: TimeInterval = 0.3
    /// 1 回に送り直すタイルの上限 (送り直しが一度に大きな塊にならないように)
    public var maxRefinePerFrame = 96
    /// 1 回でこれ以上のタイルが変わったら「動いている」とみなす (スクロール・ウィンドウ移動・動画)
    public var motionTiles = 12
    /// 可逆で送ってもこのバイト数以下なら、粗くしない (単色に近いタイル)
    public var losslessUnder = 600

    public private(set) var stats = FrameStats()
    private let tilesX: Int
    private let tilesY: Int
    /// 前回の encode で変化したタイル
    private var changedLast: [Bool]
    /// 粗く送ったまま、まだきれいに送り直していないタイル
    private var lossy: [Bool]
    private var lastChange: [TimeInterval]

    public init(width: Int, height: Int, tileSize: Int = 64) {
        self.width = width
        self.height = height
        self.tileSize = tileSize
        previous = [UInt8](repeating: 0, count: width * height * 4)
        scratch = [UInt32](repeating: 0, count: tileSize * tileSize)
        tilesX = (width + tileSize - 1) / tileSize
        tilesY = (height + tileSize - 1) / tileSize
        changedLast = [Bool](repeating: false, count: tilesX * tilesY)
        lossy = changedLast
        lastChange = [TimeInterval](repeating: 0, count: tilesX * tilesY)
    }

    /// 次回の encode で全タイルを送る
    public func reset() { hasPrevious = false }

    /// src: BGRA 画像 (各行 srcStride バイト)。送るものが無ければ nil。
    /// v2 では、変化が無くても「止まったので送り直す」タイルがあれば返す。now はテスト用
    public func encode(_ src: UnsafeRawPointer, srcStride: Int, now: TimeInterval = Date().timeIntervalSinceReferenceDate)
        -> [UInt8]? {
        let out = format == .v2 ? encodeV2(src, srcStride: srcStride, now: now) : encodeV1(src, srcStride: srcStride)
        if let o = out {
            stats.frames += 1
            stats.bytes += o.count
        }
        return out
    }

    private func encodeV1(_ src: UnsafeRawPointer, srcStride: Int) -> [UInt8]? {
        var out = ByteWriter(capacity: 64 * 1024)
        out.u32(0) // tileCount (あとで書き換える)
        var count: UInt32 = 0
        let prevStride = width * 4
        let full = !hasPrevious

        previous.withUnsafeMutableBytes { prevBuf in
            let prev = prevBuf.baseAddress!
            scratch.withUnsafeMutableBufferPointer { tileBuf in
                var ty = 0
                while ty < height {
                    let th = min(tileSize, height - ty)
                    var tx = 0
                    while tx < width {
                        let tw = min(tileSize, width - tx)
                        let rowBytes = tw * 4

                        var changed = full
                        if !changed {
                            for r in 0 ..< th {
                                if memcmp(src + (ty + r) * srcStride + tx * 4,
                                          prev + (ty + r) * prevStride + tx * 4, rowBytes) != 0 {
                                    changed = true
                                    break
                                }
                            }
                        }
                        if changed {
                            // 前回フレームを更新しつつ、タイルを連続領域へ (アルファは捨てる)
                            for r in 0 ..< th {
                                let s = src + (ty + r) * srcStride + tx * 4
                                memcpy(prev + (ty + r) * prevStride + tx * 4, s, rowBytes)
                                let sp = s.assumingMemoryBound(to: UInt32.self)
                                for c in 0 ..< tw { tileBuf[r * tw + c] = sp[c] & 0x00FF_FFFF }
                            }
                            out.u16(UInt16(tx)); out.u16(UInt16(ty))
                            out.u16(UInt16(tw)); out.u16(UInt16(th))
                            let lenAt = out.bytes.count
                            out.u32(0)
                            TileRLE.encode(UnsafeBufferPointer(rebasing: tileBuf[0 ..< tw * th]), into: &out.bytes)
                            out.patchU32(at: lenAt, UInt32(out.bytes.count - lenAt - 4))
                            count += 1
                            stats.losslessTiles += 1
                        }
                        tx += tileSize
                    }
                    ty += tileSize
                }
            }
        }
        hasPrevious = true
        if count == 0 { return nil }
        out.patchU32(at: 0, count)
        return out.bytes
    }

    private func encodeV2(_ src: UnsafeRawPointer, srcStride: Int, now: TimeInterval) -> [UInt8]? {
        let prevStride = width * 4
        let full = !hasPrevious
        var out = ByteWriter(capacity: 64 * 1024)
        out.u32(0)
        var count: UInt32 = 0

        previous.withUnsafeMutableBytes { prevBuf in
            let prev = prevBuf.baseAddress!
            // 1. 変化したタイルを調べる (何枚変わったかで「動いている」かを決めるので、先に全部見る)
            var changed = [Bool](repeating: false, count: tilesX * tilesY)
            var changedCount = 0
            for t in 0 ..< tilesX * tilesY {
                let tx = (t % tilesX) * tileSize, ty = (t / tilesX) * tileSize
                let tw = min(tileSize, width - tx), th = min(tileSize, height - ty)
                var c = full
                if !c {
                    for r in 0 ..< th where memcmp(src + (ty + r) * srcStride + tx * 4,
                                                   prev + (ty + r) * prevStride + tx * 4, tw * 4) != 0 {
                        c = true
                        break
                    }
                }
                if c {
                    changed[t] = true
                    changedCount += 1
                }
            }
            let moving = full || changedCount >= motionTiles

            scratch.withUnsafeMutableBufferPointer { tileBuf in
                func load(_ t: Int, from base: UnsafeRawPointer, stride: Int, copy: Bool)
                    -> (Int, Int, Int, Int, UnsafeBufferPointer<UInt32>) {
                    let tx = (t % tilesX) * tileSize, ty = (t / tilesX) * tileSize
                    let tw = min(tileSize, width - tx), th = min(tileSize, height - ty)
                    for r in 0 ..< th {
                        let s = base + (ty + r) * stride + tx * 4
                        if copy { memcpy(prev + (ty + r) * prevStride + tx * 4, s, tw * 4) }
                        let sp = s.assumingMemoryBound(to: UInt32.self)
                        for c in 0 ..< tw { tileBuf[r * tw + c] = sp[c] & 0x00FF_FFFF }
                    }
                    return (tx, ty, tw, th, UnsafeBufferPointer(rebasing: tileBuf[0 ..< tw * th]))
                }
                func header(_ tx: Int, _ ty: Int, _ tw: Int, _ th: Int) {
                    out.u16(UInt16(tx)); out.u16(UInt16(ty)); out.u16(UInt16(tw)); out.u16(UInt16(th))
                }

                // 2. 変化したタイル: 動いているなら粗く、そうでなければ可逆で
                for t in 0 ..< tilesX * tilesY where changed[t] {
                    let (tx, ty, tw, th, tile) = load(t, from: src, stride: srcStride, copy: true)
                    lastChange[t] = now
                    header(tx, ty, tw, th)
                    let useLossy = moving || changedLast[t]
                    if useLossy {
                        var rle: [UInt8] = []
                        TileRLE.encode(tile, into: &rle)
                        if rle.count <= losslessUnder {
                            out.u8(TileEncoding.rle24.rawValue)
                            out.u32(UInt32(rle.count))
                            out.bytes += rle
                            lossy[t] = false
                            stats.losslessTiles += 1
                        } else {
                            var half: [UInt8] = []
                            TileHalf565.encode(tile, width: tw, height: th, into: &half)
                            out.u8(TileEncoding.half565.rawValue)
                            out.u32(UInt32(half.count))
                            out.bytes += half
                            lossy[t] = true
                            stats.lossyTiles += 1
                        }
                    } else {
                        Self.writeLossless(tile, into: &out)
                        lossy[t] = false
                        stats.losslessTiles += 1
                    }
                    count += 1
                }

                // 3. 粗く送ったまま止まったタイルを、1 回だけ可逆で送り直す
                var refined = 0
                for t in 0 ..< tilesX * tilesY where lossy[t] && !changed[t] && now - lastChange[t] >= refineDelay {
                    guard refined < maxRefinePerFrame else { break }
                    let (tx, ty, tw, th, tile) = load(t, from: UnsafeRawPointer(prev), stride: prevStride, copy: false)
                    header(tx, ty, tw, th)
                    Self.writeLossless(tile, into: &out)
                    lossy[t] = false
                    refined += 1
                    count += 1
                }
                stats.refinedTiles += refined
            }
            changedLast = changed
        }
        hasPrevious = true
        if count == 0 { return nil }
        out.patchU32(at: 0, count)
        return out.bytes
    }

    /// 粗いまま残っているタイルがあるか (テスト・ログ用)
    public var hasPendingRefine: Bool { lossy.contains(true) }
}

/// ビューア側: 受信したフレームを適用していく画面バッファ (BGRA, 不透明)
public final class Framebuffer {
    public private(set) var width: Int = 0
    public private(set) var height: Int = 0
    public private(set) var pixels: [UInt8] = []

    public init() {}

    public var bytesPerRow: Int { width * 4 }

    public func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// frame payload を適用し、更新されたタイル数を返す
    @discardableResult
    public func apply(_ payload: [UInt8]) throws -> Int {
        var r = ByteReader(payload)
        let count = Int(try r.u32())
        let stride = bytesPerRow
        let (fbW, fbH) = (width, height)
        try payload.withUnsafeBufferPointer { src in
            try pixels.withUnsafeMutableBytes { dst in
                for _ in 0 ..< count {
                    let x = Int(try r.u16()), y = Int(try r.u16())
                    let w = Int(try r.u16()), h = Int(try r.u16())
                    let len = Int(try r.u32())
                    guard w > 0, h > 0, x + w <= fbW, y + h <= fbH else {
                        throw ProtocolError.invalid("タイルが画面外です (\(x),\(y) \(w)x\(h))")
                    }
                    let start = r.offset
                    try r.skip(len)
                    try TileRLE.decode(
                        UnsafeBufferPointer(rebasing: src[start ..< start + len]),
                        into: dst.baseAddress! + y * stride + x * 4, stride: stride, width: w, height: h)
                }
            }
        }
        return count
    }
}

// MARK: - フレーム形式 v2 (通信量を減らす)
//
// 考え方は「画面が変わらない間は 1 バイトも送らない」「動いている間は粗く、止まったら 1 回だけきれいに」。
// (Chrome Remote Desktop のトップオフ、TurboVNC の Automatic Lossless Refresh、RDP の段階的な精細化と同じ)
//
// frame2 payload:
//   tileCount u32
//   tile * tileCount:
//     x u16, y u16, w u16, h u16, encoding u8, dataLength u32, data
//
// encoding:
//   0 RLE24   : v1 と同じ RLE (可逆)
//   1 PALETTE : 色数 n-1 u8、パレット n * 3 バイト (B,G,R)、続いて索引の RLE (可逆。文字や UI は色が少ない)
//               制御バイト c & 0x80 != 0 → 同じ索引が (c & 0x7F) + 1 個 (索引 1 バイト)
//               c & 0x80 == 0 → 異なる索引が c + 1 個
//   2 HALF565 : 縦横 1/2 (2x2 の平均) を 16bit 色 (RGB565, LE) の RLE で (非可逆。動いている間だけ使う)

public enum FrameFormat: Equatable {
    case v1
    case v2
}

public enum TileEncoding: UInt8 {
    case rle24 = 0
    case palette = 1
    case half565 = 2
}

/// ビューアがホストに伝える対応機能 (capabilities メッセージ)
public enum ViewerCapability {
    /// frame2 (パレット・動き中の粗い画質・静止後の高画質化) を受け取れる
    public static let frame2: UInt32 = 1 << 0
}

public enum TilePalette {
    /// 色数が maxColors 以下なら、パレット形式で out に追記して true。超えたら out は変えずに false
    public static func encode(_ pixels: UnsafeBufferPointer<UInt32>, maxColors: Int = 256,
                              into out: inout [UInt8]) -> Bool {
        // 小さな開番地法の表で色を数える (タイルは最大 64x64 = 4096 画素)
        let tableSize = 1024
        var keys = [UInt32](repeating: 0, count: tableSize)
        var vals = [UInt8](repeating: 0, count: tableSize)
        var used = [Bool](repeating: false, count: tableSize)
        var palette: [UInt32] = []
        var indices = [UInt8](repeating: 0, count: pixels.count)
        var lastColor: UInt32 = 0xFFFF_FFFF
        var lastIndex: UInt8 = 0
        for (i, p) in pixels.enumerated() {
            if p == lastColor {
                indices[i] = lastIndex
                continue
            }
            var h = Int((p &* 2_654_435_761) >> 22) & (tableSize - 1)
            while used[h] && keys[h] != p { h = (h + 1) & (tableSize - 1) }
            if !used[h] {
                guard palette.count < maxColors else { return false }
                used[h] = true
                keys[h] = p
                vals[h] = UInt8(palette.count)
                palette.append(p)
            }
            lastColor = p
            lastIndex = vals[h]
            indices[i] = lastIndex
        }
        guard !palette.isEmpty else { return false }
        out.append(UInt8(palette.count - 1))
        for p in palette {
            out.append(UInt8(truncatingIfNeeded: p))
            out.append(UInt8(truncatingIfNeeded: p >> 8))
            out.append(UInt8(truncatingIfNeeded: p >> 16))
        }
        var i = 0
        let n = indices.count
        while i < n {
            let v = indices[i]
            var run = 1
            while i + run < n, run < 128, indices[i + run] == v { run += 1 }
            if run >= 3 {
                out.append(0x80 | UInt8(run - 1))
                out.append(v)
                i += run
                continue
            }
            let start = i
            var lit = 1
            i += 1
            while i < n, lit < 128 {
                if i + 2 < n, indices[i] == indices[i + 1], indices[i] == indices[i + 2] { break }
                lit += 1
                i += 1
            }
            out.append(UInt8(lit - 1))
            out.append(contentsOf: indices[start ..< start + lit])
        }
        return true
    }

    public static func decode(_ data: UnsafeBufferPointer<UInt8>, into dst: UnsafeMutableRawPointer,
                              stride: Int, width w: Int, height h: Int) throws {
        guard data.count >= 1 else { throw ProtocolError.truncated }
        let colors = Int(data[0]) + 1
        guard data.count >= 1 + colors * 3 else { throw ProtocolError.truncated }
        var palette = [UInt32](repeating: 0, count: colors)
        for k in 0 ..< colors {
            let o = 1 + k * 3
            palette[k] = 0xFF00_0000 | UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16
        }
        let total = w * h
        var written = 0
        var col = 0
        var row = dst.assumingMemoryBound(to: UInt32.self)
        var i = 1 + colors * 3
        let n = data.count

        @inline(__always) func emit(_ v: UInt32) {
            row[col] = v
            col += 1
            if col == w {
                col = 0
                row = (UnsafeMutableRawPointer(row) + stride).assumingMemoryBound(to: UInt32.self)
            }
        }
        @inline(__always) func color(_ idx: UInt8) throws -> UInt32 {
            guard Int(idx) < colors else { throw ProtocolError.invalid("パレットの範囲外") }
            return palette[Int(idx)]
        }

        while i < n {
            let c = data[i]
            i += 1
            let count = Int(c & 0x7F) + 1
            guard written + count <= total else { throw ProtocolError.invalid("タイルの画素数が多すぎます") }
            if c & 0x80 != 0 {
                guard i < n else { throw ProtocolError.truncated }
                let v = try color(data[i])
                i += 1
                for _ in 0 ..< count { emit(v) }
            } else {
                guard i + count <= n else { throw ProtocolError.truncated }
                for k in 0 ..< count { emit(try color(data[i + k])) }
                i += count
            }
            written += count
        }
        guard written == total else { throw ProtocolError.invalid("タイルの画素数が足りません (\(written)/\(total))") }
    }
}

public enum TileHalf565 {
    /// 2x2 の平均を RGB565 にして RLE。pixels は w x h (0x00RRGGBB)
    public static func encode(_ pixels: UnsafeBufferPointer<UInt32>, width w: Int, height h: Int,
                              into out: inout [UInt8]) {
        let hw = (w + 1) / 2, hh = (h + 1) / 2
        var half = [UInt16](repeating: 0, count: hw * hh)
        for by in 0 ..< hh {
            for bx in 0 ..< hw {
                var r = 0, g = 0, b = 0, cnt = 0
                for dy in 0 ..< 2 where by * 2 + dy < h {
                    for dx in 0 ..< 2 where bx * 2 + dx < w {
                        let p = pixels[(by * 2 + dy) * w + bx * 2 + dx]
                        b += Int(p & 0xFF); g += Int((p >> 8) & 0xFF); r += Int((p >> 16) & 0xFF)
                        cnt += 1
                    }
                }
                r /= cnt; g /= cnt; b /= cnt
                half[by * hw + bx] = UInt16(r >> 3) << 11 | UInt16(g >> 2) << 5 | UInt16(b >> 3)
            }
        }
        @inline(__always) func put(_ v: UInt16) {
            out.append(UInt8(truncatingIfNeeded: v))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        var i = 0
        let n = half.count
        while i < n {
            let v = half[i]
            var run = 1
            while i + run < n, run < 128, half[i + run] == v { run += 1 }
            if run >= 2 {
                out.append(0x80 | UInt8(run - 1))
                put(v)
                i += run
                continue
            }
            let start = i
            var lit = 1
            i += 1
            while i < n, lit < 128 {
                if i + 1 < n, half[i] == half[i + 1] { break }
                lit += 1
                i += 1
            }
            out.append(UInt8(lit - 1))
            for k in start ..< start + lit { put(half[k]) }
        }
    }

    public static func decode(_ data: UnsafeBufferPointer<UInt8>, into dst: UnsafeMutableRawPointer,
                              stride: Int, width w: Int, height h: Int) throws {
        let hw = (w + 1) / 2, hh = (h + 1) / 2
        let total = hw * hh
        var written = 0
        var i = 0
        let n = data.count

        @inline(__always) func expand(_ v: UInt16) -> UInt32 {
            let r5 = UInt32(v >> 11) & 0x1F, g6 = UInt32(v >> 5) & 0x3F, b5 = UInt32(v) & 0x1F
            let r = r5 << 3 | r5 >> 2, g = g6 << 2 | g6 >> 4, b = b5 << 3 | b5 >> 2
            return 0xFF00_0000 | r << 16 | g << 8 | b
        }
        @inline(__always) func emit(_ v: UInt32) {
            let bx = written % hw, by = written / hw
            for dy in 0 ..< 2 where by * 2 + dy < h {
                let row = (dst + (by * 2 + dy) * stride).assumingMemoryBound(to: UInt32.self)
                for dx in 0 ..< 2 where bx * 2 + dx < w { row[bx * 2 + dx] = v }
            }
            written += 1
        }

        while i < n {
            let c = data[i]
            i += 1
            let count = Int(c & 0x7F) + 1
            guard written + count <= total else { throw ProtocolError.invalid("タイルの画素数が多すぎます") }
            if c & 0x80 != 0 {
                guard i + 2 <= n else { throw ProtocolError.truncated }
                let v = expand(UInt16(data[i]) | UInt16(data[i + 1]) << 8)
                i += 2
                for _ in 0 ..< count { emit(v) }
            } else {
                guard i + 2 * count <= n else { throw ProtocolError.truncated }
                for _ in 0 ..< count {
                    emit(expand(UInt16(data[i]) | UInt16(data[i + 1]) << 8))
                    i += 2
                }
            }
        }
        guard written == total else { throw ProtocolError.invalid("タイルの画素数が足りません (\(written)/\(total))") }
    }
}

/// 送ったデータ量の記録 (ホストのログと、通信量の見積もり用)
public struct FrameStats: Equatable {
    public var frames = 0
    public var bytes = 0
    /// 可逆で送ったタイル (変化したもの)
    public var losslessTiles = 0
    /// 動いている間に粗く送ったタイル
    public var lossyTiles = 0
    /// 止まってから、粗く送った分をきれいに送り直したタイル
    public var refinedTiles = 0

    public init() {}
}

extension FrameEncoder {
    /// v2 の 1 タイルを、可逆の小さい方 (パレットか RLE24) で out に書く
    static func writeLossless(_ tile: UnsafeBufferPointer<UInt32>, into out: inout ByteWriter) {
        var rle: [UInt8] = []
        rle.reserveCapacity(tile.count)
        TileRLE.encode(tile, into: &rle)
        var pal: [UInt8] = []
        // RLE が十分小さい (単色に近い) ならパレットは試さない
        if rle.count > 256, TilePalette.encode(tile, into: &pal), pal.count < rle.count {
            out.u8(TileEncoding.palette.rawValue)
            out.u32(UInt32(pal.count))
            out.bytes += pal
        } else {
            out.u8(TileEncoding.rle24.rawValue)
            out.u32(UInt32(rle.count))
            out.bytes += rle
        }
    }
}

extension Framebuffer {
    /// frame2 payload を適用し、更新されたタイル数を返す
    @discardableResult
    public func apply(_ payload: [UInt8], format: FrameFormat) throws -> Int {
        guard format == .v2 else { return try apply(payload) }
        var r = ByteReader(payload)
        let count = Int(try r.u32())
        let stride = bytesPerRow
        let (fbW, fbH) = (width, height)
        try payload.withUnsafeBufferPointer { src in
            try pixels.withUnsafeMutableBytes { dstBuf in
                let dst = dstBuf.baseAddress!
                for _ in 0 ..< count {
                    let x = Int(try r.u16()), y = Int(try r.u16())
                    let w = Int(try r.u16()), h = Int(try r.u16())
                    let enc = try r.u8()
                    let len = Int(try r.u32())
                    guard w > 0, h > 0, x + w <= fbW, y + h <= fbH else {
                        throw ProtocolError.invalid("タイルが画面外です (\(x),\(y) \(w)x\(h))")
                    }
                    let start = r.offset
                    try r.skip(len)
                    let data = UnsafeBufferPointer(rebasing: src[start ..< start + len])
                    let at = dst + y * stride + x * 4
                    switch TileEncoding(rawValue: enc) {
                    case .rle24: try TileRLE.decode(data, into: at, stride: stride, width: w, height: h)
                    case .palette: try TilePalette.decode(data, into: at, stride: stride, width: w, height: h)
                    case .half565: try TileHalf565.decode(data, into: at, stride: stride, width: w, height: h)
                    case nil: throw ProtocolError.invalid("不明なタイル形式 \(enc)")
                    }
                }
            }
        }
        return count
    }
}
