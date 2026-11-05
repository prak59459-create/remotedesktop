#if os(Windows)
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

func makeCapturer(scale: Int) -> ScreenCapturer? { GDICapturer(scale: scale) }
func makeInjector() -> InputInjector { WindowsInputInjector() }
func platformSetup() { enableDPIAwareness() }
#endif
