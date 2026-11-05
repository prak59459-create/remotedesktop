/// 画面キャプチャの抽象。capture() は BGRA 画像の先頭ポインタを返す。
protocol ScreenCapturer: AnyObject {
    /// 送信する画像のサイズ (縮小後)
    var width: Int { get }
    var height: Int { get }
    var bytesPerRow: Int { get }
    /// 実際の画面サイズ (入力座標の変換に使う)
    var screenWidth: Int { get }
    var screenHeight: Int { get }
    /// 画面の解像度が変わってキャプチャを作り直す必要があるか
    var needsRecreate: Bool { get }
    func capture() -> UnsafeRawPointer?
}

/// マウス・キーボード入力をホスト OS に注入する抽象
protocol InputInjector: AnyObject {
    /// x, y は実画面のピクセル座標
    func moveMouse(x: Int, y: Int)
    func mouseButton(_ button: Int, down: Bool)
    func wheel(dx: Int32, dy: Int32)
    /// code: スキャンコード (拡張キーは 0xE000 を OR) または仮想キーコード
    func key(code: UInt16, down: Bool, virtualKey: Bool)
}
