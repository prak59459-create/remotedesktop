#if os(Windows)
import Dispatch
import CWinSys
import Foundation
import WinSDK

// マクロのキャスト付き定数は Swift に取り込まれないことがあるので自前で定義する
private let kSRCCOPY: DWORD = 0x00CC_0020
private let kCAPTUREBLT: DWORD = 0x4000_0000
private let kHALFTONE: Int32 = 4
private let kSM_CXSCREEN: Int32 = 0
private let kSM_CYSCREEN: Int32 = 1

private let kINPUT_MOUSE: DWORD = 0
private let kINPUT_KEYBOARD: DWORD = 1
private let kMOUSEEVENTF_LEFTDOWN: DWORD = 0x0002
private let kMOUSEEVENTF_LEFTUP: DWORD = 0x0004
private let kMOUSEEVENTF_RIGHTDOWN: DWORD = 0x0008
private let kMOUSEEVENTF_RIGHTUP: DWORD = 0x0010
private let kMOUSEEVENTF_MIDDLEDOWN: DWORD = 0x0020
private let kMOUSEEVENTF_MIDDLEUP: DWORD = 0x0040
private let kMOUSEEVENTF_XDOWN: DWORD = 0x0080
private let kMOUSEEVENTF_XUP: DWORD = 0x0100
private let kMOUSEEVENTF_WHEEL: DWORD = 0x0800
private let kMOUSEEVENTF_HWHEEL: DWORD = 0x1000
private let kXBUTTON1: DWORD = 0x0001
private let kXBUTTON2: DWORD = 0x0002
private let kKEYEVENTF_EXTENDEDKEY: DWORD = 0x0001
private let kKEYEVENTF_KEYUP: DWORD = 0x0002
private let kKEYEVENTF_SCANCODE: DWORD = 0x0008

/// 高 DPI 環境でも実ピクセルでキャプチャ・座標指定できるようにする
func enableDPIAwareness() {
    _ = SetProcessDPIAware()
}

func primaryScreenSize() -> (Int, Int) {
    (Int(GetSystemMetrics(kSM_CXSCREEN)), Int(GetSystemMetrics(kSM_CYSCREEN)))
}

/// GDI (BitBlt / StretchBlt) でプライマリモニタをキャプチャする
final class GDICapturer: ScreenCapturer {
    let width: Int
    let height: Int
    let screenWidth: Int
    let screenHeight: Int
    var bytesPerRow: Int { width * 4 }

    private let screenDC: HDC
    private let memDC: HDC
    private let bitmap: HBITMAP
    private let oldObject: HGDIOBJ?
    private let bits: UnsafeMutableRawPointer

    init?(scale: Int) {
        let (sw, sh) = primaryScreenSize()
        guard sw > 0, sh > 0 else { return nil }
        screenWidth = sw
        screenHeight = sh
        width = max(1, sw / max(1, scale))
        height = max(1, sh / max(1, scale))

        guard let sdc = GetDC(nil) else { return nil }
        guard let mdc = CreateCompatibleDC(sdc) else {
            ReleaseDC(nil, sdc)
            return nil
        }

        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = LONG(width)
        bmi.bmiHeader.biHeight = -LONG(height) // 負 = トップダウン
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = 0 // BI_RGB

        var ptr: UnsafeMutableRawPointer? = nil
        guard let bmp = CreateDIBSection(mdc, &bmi, 0 /* DIB_RGB_COLORS */, &ptr, nil, 0), let p = ptr else {
            DeleteDC(mdc)
            ReleaseDC(nil, sdc)
            return nil
        }
        screenDC = sdc
        memDC = mdc
        bitmap = bmp
        bits = p
        oldObject = SelectObject(mdc, HGDIOBJ(bmp))
        if scale > 1 {
            SetStretchBltMode(mdc, kHALFTONE)
            SetBrushOrgEx(mdc, 0, 0, nil)
        }
    }

    deinit {
        if let o = oldObject { SelectObject(memDC, o) }
        DeleteObject(HGDIOBJ(bitmap))
        DeleteDC(memDC)
        ReleaseDC(nil, screenDC)
    }

    var needsRecreate: Bool {
        let (sw, sh) = primaryScreenSize()
        return sw != screenWidth || sh != screenHeight
    }

    func capture() -> UnsafeRawPointer? {
        // ロック画面や UAC のセキュアデスクトップ中は失敗するが、その場合は前回の内容のまま
        if width == screenWidth && height == screenHeight {
            _ = BitBlt(memDC, 0, 0, Int32(width), Int32(height), screenDC, 0, 0, kSRCCOPY | kCAPTUREBLT)
        } else {
            _ = StretchBlt(memDC, 0, 0, Int32(width), Int32(height),
                           screenDC, 0, 0, Int32(screenWidth), Int32(screenHeight), kSRCCOPY | kCAPTUREBLT)
        }
        _ = GdiFlush()
        return UnsafeRawPointer(bits)
    }
}

/// SendInput でマウス・キーボード入力を注入する
final class WindowsInputInjector: InputInjector {
    func moveMouse(x: Int, y: Int) {
        _ = SetCursorPos(Int32(x), Int32(y))
    }

    func mouseButton(_ button: Int, down: Bool) {
        var flags: DWORD
        var data: DWORD = 0
        switch button {
        case 0: flags = down ? kMOUSEEVENTF_LEFTDOWN : kMOUSEEVENTF_LEFTUP
        case 1: flags = down ? kMOUSEEVENTF_RIGHTDOWN : kMOUSEEVENTF_RIGHTUP
        case 2: flags = down ? kMOUSEEVENTF_MIDDLEDOWN : kMOUSEEVENTF_MIDDLEUP
        case 3: flags = down ? kMOUSEEVENTF_XDOWN : kMOUSEEVENTF_XUP; data = kXBUTTON1
        case 4: flags = down ? kMOUSEEVENTF_XDOWN : kMOUSEEVENTF_XUP; data = kXBUTTON2
        default: return
        }
        sendMouse(flags: flags, data: data)
    }

    func wheel(dx: Int32, dy: Int32) {
        if dy != 0 { sendMouse(flags: kMOUSEEVENTF_WHEEL, data: DWORD(bitPattern: dy)) }
        if dx != 0 { sendMouse(flags: kMOUSEEVENTF_HWHEEL, data: DWORD(bitPattern: dx)) }
    }

    func key(code: UInt16, down: Bool, virtualKey: Bool) {
        var input = INPUT()
        input.type = kINPUT_KEYBOARD
        var flags: DWORD = down ? 0 : kKEYEVENTF_KEYUP
        if virtualKey {
            input.ki.wVk = WORD(code)
            input.ki.wScan = WORD(MapVirtualKeyW(UINT(code), 0 /* MAPVK_VK_TO_VSC */))
        } else {
            input.ki.wVk = 0
            input.ki.wScan = WORD(code & 0x00FF)
            flags |= kKEYEVENTF_SCANCODE
            if code & 0xFF00 == 0xE000 { flags |= kKEYEVENTF_EXTENDEDKEY }
        }
        input.ki.dwFlags = flags
        input.ki.time = 0
        input.ki.dwExtraInfo = 0
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.size))
    }

    func text(_ s: String) {
        // KEYEVENTF_UNICODE (0x0004): UTF-16 の単位ごとに down / up を送る
        var inputs: [INPUT] = []
        for unit in s.utf16 {
            for up in [false, true] {
                var input = INPUT()
                input.type = kINPUT_KEYBOARD
                input.ki.wVk = 0
                input.ki.wScan = WORD(unit)
                input.ki.dwFlags = 0x0004 | (up ? kKEYEVENTF_KEYUP : 0)
                input.ki.time = 0
                input.ki.dwExtraInfo = 0
                inputs.append(input)
            }
        }
        guard !inputs.isEmpty else { return }
        _ = inputs.withUnsafeMutableBufferPointer {
            SendInput(UINT($0.count), $0.baseAddress, Int32(MemoryLayout<INPUT>.size))
        }
    }

    private func sendMouse(flags: DWORD, data: DWORD) {
        var input = INPUT()
        input.type = kINPUT_MOUSE
        input.mi.dx = 0
        input.mi.dy = 0
        input.mi.mouseData = data
        input.mi.dwFlags = flags
        input.mi.time = 0
        input.mi.dwExtraInfo = 0
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.size))
    }
}

/// 接続を許可するか、最前面のダイアログで確認する (既定ボタンは「いいえ」)
func askConsent(name: String, fingerprint: String, peer: String, isNew: Bool) -> Bool {
    let text = """
    \(isNew ? "新しい端末" : "端末") 「\(name)」がこの PC への接続を求めています。

    接続元: \(peer)
    端末の指紋: \(fingerprint)

    許可すると、この PC の画面を見られ、マウスとキーボードを操作されます。
    心当たりがなければ「いいえ」を押してください。
    """
    let flags: UINT = 0x4 /* MB_YESNO */ | 0x30 /* MB_ICONWARNING */ | 0x100 /* MB_DEFBUTTON2 */
        | 0x1_0000 /* MB_SETFOREGROUND */ | 0x4_0000 /* MB_TOPMOST */
    // 60 秒で答えがなければ「いいえ」扱い (席を外しているあいだに確認待ちが溜まらないように)。
    // MessageBoxTimeoutW は user32.dll にある (ヘッダーには無い) ので、あれば使う。
    typealias MessageBoxTimeout = @convention(c) (HWND?, LPCWSTR?, LPCWSTR?, UINT, WORD, DWORD) -> Int32
    let timeoutFn: MessageBoxTimeout? = "user32.dll".withCString(encodedAs: UTF16.self) { lib in
        guard let module = GetModuleHandleW(lib), let proc = GetProcAddress(module, "MessageBoxTimeoutW") else { return nil }
        return unsafeBitCast(proc, to: MessageBoxTimeout.self)
    }
    let r = text.withCString(encodedAs: UTF16.self) { t in
        "RemoteDesktop — 接続の確認 (60 秒で自動的に拒否)".withCString(encodedAs: UTF16.self) { c in
            if let f = timeoutFn { return f(nil, t, c, flags, 0, 60_000) }
            return MessageBoxW(nil, t, c, flags)
        }
    }
    return r == 6 // IDYES (時間切れは 32000)
}

// MARK: - 切断時の画面保護

func performDisconnectAction(_ action: DisconnectAction) {
    switch action {
    case .blank:
        // HWND_BROADCAST へ SC_MONITORPOWER(2 = 電源オフ)。応答しないウィンドウで止まらないよう Post で送る
        _ = PostMessageW(HWND(bitPattern: 0xFFFF), 0x0112 /* WM_SYSCOMMAND */, 0xF170 /* SC_MONITORPOWER */, 2)
    case .lock:
        _ = LockWorkStation()
    case .none:
        break
    }
}

// MARK: - 管理者権限の確認

func isRunningElevated() -> Bool {
    var token: HANDLE? = nil
    guard OpenProcessToken(GetCurrentProcess(), DWORD(0x0008) /* TOKEN_QUERY */, &token), let t = token else { return false }
    defer { CloseHandle(t) }
    var elevation = TOKEN_ELEVATION()
    var size: DWORD = 0
    guard GetTokenInformation(t, TokenElevation, &elevation, DWORD(MemoryLayout<TOKEN_ELEVATION>.size), &size) else {
        return false
    }
    return elevation.TokenIsElevated != 0
}

// MARK: - Windows イベントログ (監査ログの写し)

private let eventSource: HANDLE? = "RemoteDesktop".withCString(encodedAs: UTF16.self) { RegisterEventSourceW(nil, $0) }

func writeEventLog(_ line: String, warning: Bool) {
    guard let h = eventSource else { return }
    line.withCString(encodedAs: UTF16.self) { p in
        var strings: [LPCWSTR?] = [p]
        _ = strings.withUnsafeMutableBufferPointer { buf in
            ReportEventW(h, WORD(warning ? 0x0002 : 0x0004), 0, 1000, nil, 1, 0, buf.baseAddress, nil)
        }
    }
}

// MARK: - 接続中の表示 (画面上部の帯)

/// 遠隔操作されている間、画面上部に常に赤い帯を出す。その場にいる人が気づけるように。
final class ConnectionIndicator {
    static let shared = ConnectionIndicator()
    private var hwnd: HWND?
    private let ready = DispatchSemaphore(value: 0)
    private var started = false
    private let lock = NSLock()

    private func start() {
        lock.lock()
        defer { lock.unlock() }
        if started { return }
        started = true
        Thread { [self] in runLoop() }.start()
        _ = ready.wait(timeout: .now() + 3)
    }

    func show(_ text: String) {
        start()
        guard let h = hwnd else { return }
        text.withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(h, $0) }
        _ = InvalidateRect(h, nil, true)
        _ = ShowWindow(h, 4 /* SW_SHOWNOACTIVATE */)
    }

    func hide() {
        guard let h = hwnd else { return }
        _ = ShowWindow(h, 0 /* SW_HIDE */)
    }

    private func runLoop() {
        let hInstance = GetModuleHandleW(nil)
        let className = Array("RDHostIndicator".utf16) + [0]
        className.withUnsafeBufferPointer { cls in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { hwnd, msg, wParam, lParam in
                if msg == 0x000F /* WM_PAINT */ {
                    var ps = PAINTSTRUCT()
                    let dc = BeginPaint(hwnd, &ps)
                    var rect = RECT()
                    _ = GetClientRect(hwnd, &rect)
                    let brush = CreateSolidBrush(0x0000_2BC8) // 赤 (BGR)
                    _ = FillRect(dc, &rect, brush)
                    _ = DeleteObject(HGDIOBJ(brush))
                    var buf = [WCHAR](repeating: 0, count: 256)
                    let n = GetWindowTextW(hwnd, &buf, 256)
                    _ = SetBkMode(dc, 1 /* TRANSPARENT */)
                    _ = SetTextColor(dc, 0x00FF_FFFF)
                    _ = DrawTextW(dc, buf, n, &rect, 0x1 | 0x4 | 0x20 /* DT_CENTER | DT_VCENTER | DT_SINGLELINE */)
                    _ = EndPaint(hwnd, &ps)
                    return 0
                }
                return DefWindowProcW(hwnd, msg, wParam, lParam)
            }
            wc.hInstance = hInstance
            wc.lpszClassName = cls.baseAddress
            _ = RegisterClassW(&wc)
            let width: Int32 = 460, height: Int32 = 30
            let x = (GetSystemMetrics(0) - width) / 2
            // TOPMOST | TOOLWINDOW | TRANSPARENT(クリックを通す) | LAYERED | NOACTIVATE
            let exStyle: DWORD = 0x8 | 0x80 | 0x20 | 0x8_0000 | 0x800_0000
            hwnd = CreateWindowExW(exStyle, cls.baseAddress, nil, 0x8000_0000 /* WS_POPUP */,
                                   x, 0, width, height, nil, nil, hInstance, nil)
            if let h = hwnd { _ = SetLayeredWindowAttributes(h, 0, 230, 0x2 /* LWA_ALPHA */) }
        }
        ready.signal()
        var msg = MSG()
        while GetMessageW(&msg, nil, 0, 0) {
            _ = TranslateMessage(&msg)
            _ = DispatchMessageW(&msg)
        }
    }
}

func showConnectionIndicator(_ text: String?) {
    if let t = text { ConnectionIndicator.shared.show(t) } else { ConnectionIndicator.shared.hide() }
}

func makeCapturer(scale: Int) -> ScreenCapturer? { GDICapturer(scale: scale) }

func computerName() -> String {
    ProcessInfo.processInfo.environment["COMPUTERNAME"] ?? "RDHost"
}

/// 同じ LAN に Bonjour (DNS-SD) で知らせる。失敗したら理由を返す。
/// 受信には Windows 標準の mDNS (UDP 5353) が使われる。ネットワークが「パブリック」だと届かないことがある。
func advertiseBonjour(name: String, port: UInt16, ip: String?) -> String? {
    var ip4: UInt32 = 0
    if let ip {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        if parts.count == 4 {
            // ネットワークバイトオーダー (メモリ上で a.b.c.d の順)
            ip4 = parts[0] | parts[1] << 8 | parts[2] << 16 | parts[3] << 24
        }
    }
    let rc = "\(name).\(rdBonjourServiceTypeName).local".withCString(encodedAs: UTF16.self) { inst in
        "\(name).local".withCString(encodedAs: UTF16.self) { host in
            rd_mdns_register(inst, host, numericCast(ip4), port)
        }
    }
    return rc == 0 ? nil : "Windows のエラー \(rc)"
}
func makeInjector() -> InputInjector { WindowsInputInjector() }
func platformSetup() { enableDPIAwareness() }
#endif
