#if os(Windows)
import Foundation
import WinSDK

// Win32 を Swift から使うための小さな道具。
// マクロで定義された定数は Swift に取り込まれないことがあるので、使うものは自前で定義する。

enum WM {
    static let create: UINT = 0x0001, destroy: UINT = 0x0002, size: UINT = 0x0005, paint: UINT = 0x000F
    static let close: UINT = 0x0010, eraseBkgnd: UINT = 0x0014, setFont: UINT = 0x0030, getMinMaxInfo: UINT = 0x0024
    static let drawItem: UINT = 0x002B, measureItem: UINT = 0x002C, setIcon: UINT = 0x0080
    static let command: UINT = 0x0111, timer: UINT = 0x0113, sysCommand: UINT = 0x0112
    static let ctlColorEdit: UINT = 0x0133, ctlColorListBox: UINT = 0x0134, ctlColorBtn: UINT = 0x0135
    static let ctlColorStatic: UINT = 0x0138
    static let mouseMove: UINT = 0x0200, lButtonDown: UINT = 0x0201, lButtonUp: UINT = 0x0202
    static let lButtonDblClk: UINT = 0x0203, rButtonUp: UINT = 0x0205, setCursor: UINT = 0x0020
    static let app: UINT = 0x8000
}

enum Style {
    static let child: DWORD = 0x4000_0000, visible: DWORD = 0x1000_0000, tabStop: DWORD = 0x0001_0000
    static let vScroll: DWORD = 0x0020_0000, border: DWORD = 0x0080_0000, clipChildren: DWORD = 0x0200_0000
    static let overlapped: DWORD = 0x0000_0000, caption: DWORD = 0x00C0_0000, sysMenu: DWORD = 0x0008_0000
    static let minimizeBox: DWORD = 0x0002_0000
    static let exClientEdge: DWORD = 0x0000_0200
    // ボタン
    static let bsAutoCheckbox: DWORD = 0x3, bsOwnerDraw: DWORD = 0xB
    // エディット
    static let esAutoHScroll: DWORD = 0x80, esMultiline: DWORD = 0x4, esReadOnly: DWORD = 0x800
    static let esAutoVScroll: DWORD = 0x40, esNumber: DWORD = 0x2000
    // コンボボックス
    static let cbsDropDownList: DWORD = 0x3
    // リストボックス
    static let lbsNotify: DWORD = 0x1, lbsOwnerDrawFixed: DWORD = 0x10, lbsNoIntegralHeight: DWORD = 0x100
}

enum Msg {
    static let bmGetCheck: UINT = 0x00F0, bmSetCheck: UINT = 0x00F1
    static let cbAddString: UINT = 0x0143, cbGetCurSel: UINT = 0x0147, cbSetCurSel: UINT = 0x014E
    static let lbAddString: UINT = 0x0180, lbResetContent: UINT = 0x0184, lbGetCurSel: UINT = 0x0188
    static let emSetSel: UINT = 0x00B1, emReplaceSel: UINT = 0x00C2, emSetCueBanner: UINT = 0x1501
    static let emGetLineCount: UINT = 0x00BA
}

/// COLORREF (0x00BBGGRR)
func rgb(_ r: Int, _ g: Int, _ b: Int) -> COLORREF {
    COLORREF(r & 0xFF) | COLORREF(g & 0xFF) << 8 | COLORREF(b & 0xFF) << 16
}

func lerpColor(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ t: Double) -> COLORREF {
    rgb(a.0 + Int(Double(b.0 - a.0) * t), a.1 + Int(Double(b.1 - a.1) * t), a.2 + Int(Double(b.2 - a.2) * t))
}

/// 文字列を NUL 終端の UTF-16 にして渡す
func withWide<T>(_ s: String, _ body: (UnsafePointer<WCHAR>) -> T) -> T {
    s.withCString(encodedAs: UTF16.self, body)
}

func wparam(_ p: UnsafeMutableRawPointer?) -> WPARAM { WPARAM(UInt(bitPattern: p)) }
func lparam(_ p: UnsafeMutableRawPointer?) -> LPARAM { LPARAM(Int(bitPattern: p)) }
func lresult(_ p: UnsafeMutableRawPointer?) -> LRESULT { LRESULT(Int(bitPattern: p)) }
func loword(_ v: WPARAM) -> Int { Int(v & 0xFFFF) }
func hiword(_ v: WPARAM) -> Int { Int((v >> 16) & 0xFFFF) }
func xFromLParam(_ l: LPARAM) -> Int32 { Int32(Int16(truncatingIfNeeded: l & 0xFFFF)) }
func yFromLParam(_ l: LPARAM) -> Int32 { Int32(Int16(truncatingIfNeeded: (l >> 16) & 0xFFFF)) }

func makeRect(_ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) -> RECT {
    RECT(left: x, top: y, right: x + w, bottom: y + h)
}

func contains(_ r: RECT, _ x: Int32, _ y: Int32) -> Bool {
    x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

/// フォント (高さはピクセル。負の値 = 文字の高さ)
func makeFont(_ face: String, _ px: Int32, bold: Bool = false) -> HFONT? {
    withWide(face) { f in
        CreateFontW(-px, 0, 0, 0, bold ? 600 : 400, 0, 0, 0, 1 /* DEFAULT_CHARSET */, 0, 0,
                    5 /* CLEARTYPE_QUALITY */, 0, f)
    }
}

/// 描画の道具 (ダブルバッファ上で使う)
struct Painter {
    let dc: HDC

    func fill(_ r: RECT, _ color: COLORREF) {
        var rr = r
        let b = CreateSolidBrush(color)
        _ = FillRect(dc, &rr, b)
        _ = DeleteObject(HGDIOBJ(b))
    }

    /// 角の丸い四角 (塗りと枠)
    func roundRect(_ r: RECT, radius: Int32, fill: COLORREF, border: COLORREF? = nil) {
        let brush = CreateSolidBrush(fill)
        let pen = border.map { CreatePen(0 /* PS_SOLID */, 1, $0) } ?? CreatePen(5 /* PS_NULL */, 0, 0)
        let oldB = SelectObject(dc, HGDIOBJ(brush))
        let oldP = SelectObject(dc, HGDIOBJ(pen))
        _ = RoundRect(dc, r.left, r.top, r.right, r.bottom, radius, radius)
        _ = SelectObject(dc, oldB)
        _ = SelectObject(dc, oldP)
        _ = DeleteObject(HGDIOBJ(brush))
        _ = DeleteObject(HGDIOBJ(pen))
    }

    /// 横方向のグラデーション。radius > 0 なら角を丸める
    func gradient(_ r: RECT, _ stops: [(Int, Int, Int)], radius: Int32 = 0) {
        var region: HRGN?
        if radius > 0 {
            region = CreateRoundRectRgn(r.left, r.top, r.right + 1, r.bottom + 1, radius, radius)
            _ = SelectClipRgn(dc, region)
        }
        let w = max(1, Int(r.right - r.left))
        let strips = min(w, 160)
        for i in 0 ..< strips {
            let t = Double(i) / Double(max(1, strips - 1))
            let seg = t * Double(stops.count - 1)
            let k = min(stops.count - 2, Int(seg))
            let color = lerpColor(stops[k], stops[k + 1], seg - Double(k))
            let x0 = r.left + Int32(w * i / strips), x1 = r.left + Int32(w * (i + 1) / strips)
            fill(RECT(left: x0, top: r.top, right: x1, bottom: r.bottom), color)
        }
        if let rg = region {
            _ = SelectClipRgn(dc, nil)
            _ = DeleteObject(HGDIOBJ(rg))
        }
    }

    func circle(_ cx: Int32, _ cy: Int32, _ radius: Int32, _ color: COLORREF) {
        roundRect(RECT(left: cx - radius, top: cy - radius, right: cx + radius, bottom: cy + radius),
                  radius: radius * 2, fill: color)
    }

    /// 文字。flags は DT_* (既定: 左寄せ・1 行・上下中央)
    func text(_ s: String, _ r: RECT, font: HFONT?, color: COLORREF, flags: UINT = 0x0 | 0x20 | 0x4 | 0x8000) {
        var rr = r
        let old = SelectObject(dc, HGDIOBJ(font))
        _ = SetBkMode(dc, 1 /* TRANSPARENT */)
        _ = SetTextColor(dc, color)
        _ = withWide(s) { DrawTextW(dc, $0, -1, &rr, flags) }
        _ = SelectObject(dc, old)
    }

    /// 折り返す文字 (DT_WORDBREAK)
    func paragraph(_ s: String, _ r: RECT, font: HFONT?, color: COLORREF) {
        text(s, r, font: font, color: color, flags: 0x10 /* DT_WORDBREAK */)
    }

    /// 文字の幅
    func measure(_ s: String, font: HFONT?) -> Int32 {
        let old = SelectObject(dc, HGDIOBJ(font))
        var size = SIZE()
        _ = withWide(s) { GetTextExtentPoint32W(dc, $0, Int32(s.utf16.count), &size) }
        _ = SelectObject(dc, old)
        return size.cx
    }

    func icon(_ h: HICON?, _ x: Int32, _ y: Int32, _ size: Int32) {
        guard let h else { return }
        _ = DrawIconEx(dc, x, y, h, size, size, 0, nil, 3 /* DI_NORMAL */)
    }
}

/// クリップボードに文字列を入れる
func copyToClipboard(_ s: String, owner: HWND?) {
    guard OpenClipboard(owner) else { return }
    defer { _ = CloseClipboard() }
    _ = EmptyClipboard()
    let units = Array(s.utf16) + [0]
    guard let mem = GlobalAlloc(0x0002 /* GMEM_MOVEABLE */, SIZE_T(units.count * 2)),
          let p = GlobalLock(mem) else { return }
    units.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    _ = GlobalUnlock(mem)
    _ = SetClipboardData(13 /* CF_UNICODETEXT */, mem)
}

/// 実行ファイルのフォルダ
func exeDirectory() -> String {
    var buf = [WCHAR](repeating: 0, count: 1024)
    let n = GetModuleFileNameW(nil, &buf, DWORD(buf.count))
    let path = String(decoding: buf[0 ..< Int(n)], as: UTF16.self)
    return (path as NSString).deletingLastPathComponent
}

func exePath() -> String {
    var buf = [WCHAR](repeating: 0, count: 1024)
    let n = GetModuleFileNameW(nil, &buf, DWORD(buf.count))
    return String(decoding: buf[0 ..< Int(n)], as: UTF16.self)
}

/// .ico ファイルを読み込む
func loadIcon(_ path: String, size: Int32) -> HICON? {
    let h = withWide(path) { LoadImageW(nil, $0, 1 /* IMAGE_ICON */, size, size, 0x10 /* LR_LOADFROMFILE */) }
    return h.map { HICON(OpaquePointer($0)) }
}

/// コモンコントロール 6 (Windows の見た目のボタン・入力欄) を使えるようにする。
/// 実行ファイルにマニフェストを埋め込む代わりに、起動時にアクティベーションコンテキストを作る。
func enableVisualStyles() {
    let manifest = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
      <dependency><dependentAssembly>
        <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0"
          processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
      </dependentAssembly></dependency>
    </assembly>
    """
    let path = NSTemporaryDirectory() + "RemoteDesktopHost.manifest"
    guard (try? manifest.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return }
    withWide(path) { p in
        var ctx = ACTCTXW()
        ctx.cbSize = ULONG(MemoryLayout<ACTCTXW>.size)
        ctx.lpSource = p
        let raw: HANDLE? = CreateActCtxW(&ctx)
        guard let h = raw, Int(bitPattern: h) != -1 /* INVALID_HANDLE_VALUE */ else { return }
        var cookie: ULONG_PTR = 0
        _ = ActivateActCtx(h, &cookie)
    }
    // この状態で読み込むと、バージョン 6 のコモンコントロールが使われる
    if let lib = withWide("comctl32.dll", { LoadLibraryW($0) }),
       let proc = GetProcAddress(lib, "InitCommonControls") {
        typealias Fn = @convention(c) () -> Void
        unsafeBitCast(proc, to: Fn.self)()
    }
}

// MARK: - サインイン時の起動 (HKCU\...\Run)

enum StartupRegistration {
    private static let subKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    private static let valueName = "RemoteDesktopHost"
    private static var hkcu: HKEY? { HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001))) }

    static var isEnabled: Bool {
        withWide(subKey) { k in
            withWide(valueName) { v in
                RegGetValueW(hkcu, k, v, 0x0000_0002 /* RRF_RT_REG_SZ */, nil, nil, nil) == 0
            }
        }
    }

    static func set(_ on: Bool) {
        withWide(subKey) { k in
            withWide(valueName) { v in
                if on {
                    let cmd = "\"\(exePath())\" --minimized"
                    let units = Array(cmd.utf16) + [0]
                    _ = units.withUnsafeBytes { b in
                        RegSetKeyValueW(hkcu, k, v, 1 /* REG_SZ */, b.baseAddress, DWORD(b.count))
                    }
                } else {
                    _ = RegDeleteKeyValueW(hkcu, k, v)
                }
            }
        }
    }
}

// MARK: - BMP の保存 (CI での画面確認用)

func saveWindowBitmap(_ hwnd: HWND, to path: String) -> Bool {
    var rc = RECT()
    _ = GetClientRect(hwnd, &rc)
    let w = rc.right - rc.left, h = rc.bottom - rc.top
    guard w > 0, h > 0, let screen = GetDC(hwnd) else { return false }
    defer { _ = ReleaseDC(hwnd, screen) }
    guard let mem = CreateCompatibleDC(screen), let bmp = CreateCompatibleBitmap(screen, w, h) else { return false }
    defer { _ = DeleteDC(mem); _ = DeleteObject(HGDIOBJ(bmp)) }
    let old = SelectObject(mem, HGDIOBJ(bmp))
    // 子ウィンドウ (ボタン・入力欄) も含めて描かせる。PW_CLIENTONLY | PW_RENDERFULLCONTENT
    _ = PrintWindow(hwnd, mem, 0x1 | 0x2)
    _ = SelectObject(mem, old)

    var info = BITMAPINFO()
    info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
    info.bmiHeader.biWidth = w
    info.bmiHeader.biHeight = -h // 上から下
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    info.bmiHeader.biCompression = 0 // BI_RGB
    var pixels = [UInt8](repeating: 0, count: Int(w * h * 4))
    let lines = pixels.withUnsafeMutableBytes {
        GetDIBits(mem, bmp, 0, UINT(h), $0.baseAddress, &info, 0 /* DIB_RGB_COLORS */)
    }
    guard lines == h else { return false }

    var file: [UInt8] = []
    func u16(_ v: Int) { file += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func u32(_ v: Int) { file += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    let dataSize = pixels.count
    file += [0x42, 0x4D]; u32(54 + dataSize); u32(0); u32(54) // BITMAPFILEHEADER
    u32(40); u32(Int(w)); u32(Int(Int32(-h)) & 0xFFFF_FFFF); u16(1); u16(32); u32(0); u32(dataSize) // BITMAPINFOHEADER
    u32(2835); u32(2835); u32(0); u32(0)
    file += pixels
    return FileManager.default.createFile(atPath: path, contents: Data(file))
}
#endif
