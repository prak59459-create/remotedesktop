# remotedesktop

SwiftPM で作ったシンプルなリモートデスクトップです。Mac から Windows の画面を見て操作します。

| 実行ファイル | 動かす場所 | 役割 |
|---|---|---|
| `RDHost.exe` | **Windows**（操作される側） | 画面キャプチャ (GDI) を配信し、受け取ったマウス・キーボード入力を `SendInput` で注入 |
| `RDViewer` | **macOS**（操作する側） | 画面を表示し、マウス・キーボード・スクロールを送信 |

> ⚠️ **セキュリティ機能はありません**（認証なし・暗号化なし）。ポートに届く人は誰でも PC を操作できます。信頼できる LAN 内だけで使い、インターネットに公開しないでください。

## Windows 側 (RDHost.exe)

### EXE の入手
GitHub Actions の `build` ワークフローが Windows 用 EXE を作ります。Actions の実行結果から成果物 **`RDHost-windows-x64`** をダウンロードしてください（`RDHost.exe` と、必要な Swift ランタイム DLL が同じフォルダに入っています。フォルダごと使ってください）。

自分でビルドする場合は [Swift for Windows](https://www.swift.org/install/windows/) を入れて:

```bash
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
```

`dist\RDHost\RDHost.exe` と `dist\RDHost-windows-x64.zip` ができます。

### 起動

```bash
RDHost.exe
```

オプション: `--port 5999`（待ち受けポート）、`--fps 30`（最大フレームレート）、`--scale 2`（縦横 1/2 に縮小して送信。回線が遅いとき用）。

初回起動時に Windows ファイアウォールの確認が出たら「プライベートネットワーク」を許可してください。

## Mac 側 (RDViewer)

```bash
swift run -c release RDViewer
```

接続ダイアログに Windows の IP アドレスを入力して「接続」。`swift run -c release RDViewer 192.168.0.10` のように引数で指定するとすぐ接続します。

- ⌘ は既定で **Ctrl** として送ります（⌘C / ⌘V でコピー・貼り付け）。ダイアログのチェックを外すと Windows キーになります。
- ⌘Q（終了）と ⌘N（新しい接続）は Mac 側で使います。
- メニュー「リモート」から Windows キー、Ctrl+Shift+Esc、Alt+Tab を送れます。
- JIS キーボードの「英数」「かな」は IME オフ / オンとして送ります。
- キーは物理位置（スキャンコード）で送るので、Windows 側のキーボード配列設定どおりに入力されます。

## 仕組み

- TCP 1 本。メッセージは `[type u8][length u32][payload]`（リトルエンディアン）。
- 画面を 64×64 のタイルに分け、前回から変わったタイルだけを RLE（24bit 色）で送ります。
- ビューアがフレームを処理し終えたら ACK を返し、ホストはそれを待ってから次を送るので、遅い回線でも遅延が溜まりません。

```
Sources/
  RDCore/    プロトコル、ソケット (Winsock / BSD)、タイル差分コーデック
  RDHost/    Windows: GDI キャプチャ + SendInput（Windows 以外ではテストパターン配信）
  RDViewer/  macOS: AppKit ビューア（--headless で GUI なしの受信テスト）
```

### 動作確認（Windows / Mac がなくても）

Windows 以外で `RDHost` を動かすとテストパターンを配信し、受け取った入力をログに出します。

```bash
swift run -c release RDHost --port 6001
```

```bash
swift run -c release RDViewer --headless 127.0.0.1 6001 --frames 90 --out screen.ppm
```

## 制限

- プライマリモニタのみ。音声・クリップボード共有・ファイル転送なし。
- ロック画面や UAC の確認画面は（Windows の仕様上）キャプチャ・操作できません。Ctrl+Alt+Del も送れません。
- 圧縮は簡易 RLE なので、動画など変化の多い画面は帯域を多く使います（`--scale 2` で軽くなります）。
