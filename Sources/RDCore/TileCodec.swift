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

    public init(width: Int, height: Int, tileSize: Int = 64) {
        self.width = width
        self.height = height
        self.tileSize = tileSize
        previous = [UInt8](repeating: 0, count: width * height * 4)
        scratch = [UInt32](repeating: 0, count: tileSize * tileSize)
    }

    /// 次回の encode で全タイルを送る
    public func reset() { hasPrevious = false }

    /// src: BGRA 画像 (各行 srcStride バイト)。変化が無ければ nil。
    public func encode(_ src: UnsafeRawPointer, srcStride: Int) -> [UInt8]? {
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
