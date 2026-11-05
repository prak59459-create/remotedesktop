# remotedesktop

SwiftPM で作ったリモートデスクトップです。Mac から Windows の画面を見て操作します。
通信はすべて**暗号化・相互認証**され、**ペアリングした端末だけ**が接続できます（詳細は [SECURITY.md](SECURITY.md)）。

| 実行ファイル | 動かす場所 | 役割 |
|---|---|---|
| `RDHost.exe` | **Windows**（操作される側） | 画面キャプチャ (GDI) を配信し、受け取ったマウス・キーボード入力を `SendInput` で注入 |
| `RDViewer` | **macOS**（操作する側） | 画面を表示し、マウス・キーボード・スクロールを送信 |

## セキュリティの概要

- **Noise Protocol（`Noise_XX_25519_ChaChaPoly_SHA256`）**で暗号化と相互認証。平文で通信するモードはありません。
- **パスワードなし。** 端末ごとの鍵で認証し、ホストは登録済みの端末だけを受け入れます。
- **ペアリングコード**にホストの指紋が入っているので、初回接続でもなりすましホスト（中間者攻撃）を自動で検出します。コードは 1 回限り・10 分で失効・5 回間違えると無効。
- 秘密鍵は **Windows DPAPI / macOS キーチェーン**で保護。
- 総当たり対策（IP ごとに指数的ブロック）、認証前の接続数・時間制限、接続時の承認ダイアログ（`--confirm`）、監査ログ、端末の失効（接続中のセッションも即切断）。

> 第三者のセキュリティ監査は受けていません。限界は [SECURITY.md](SECURITY.md) の「既知の限界」を見てください。インターネットに直接公開せず、外から使うときは VPN などを併用してください。

## 使い方

### 1. Windows 側 (RDHost.exe)

GitHub Actions の `build` ワークフローの成果物 **`RDHost-windows-x64`** をダウンロードします（`RDHost.exe` と Swift ランタイム DLL が同じフォルダに入っています。フォルダごと使ってください）。

自分でビルドする場合は [Swift for Windows](https://www.swift.org/install/windows/) を入れて:

```bash
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
```

**初回（端末の登録）**は `--pair` 付きで起動します:

```bash
RDHost.exe --pair
```

`ペアリングコード: XXXX-XXXX-XXXX-XXXX-XXXX-XXXX` が表示されます（10 分間・1 回限り）。2 回目以降は `RDHost.exe` だけで起動できます。

| オプション | 説明 |
|---|---|
| `--pair` | 新しい端末を登録するためのコードを表示 |
| `--confirm` | 接続のたびに Windows 側で許可/拒否のダイアログを出す |
| `--bind 192.168.0.10` | 待ち受けるアドレスを限定（既定は全インターフェース） |
| `--port 5999` / `--fps 30` / `--scale 2` | ポート、最大フレームレート、縮小率 |
| `--list` / `--revoke ID` | 登録済み端末の一覧 / 取り消し（ID は指紋の先頭 4 文字以上） |
| `--fingerprint` | このホストの指紋を表示 |

初回起動時に Windows ファイアウォールの確認が出たら「プライベートネットワーク」だけを許可してください。

### 2. Mac 側 (RDViewer)

```bash
swift run -c release RDViewer
```

接続ダイアログに Windows の IP アドレスと、**初回だけ**ペアリングコードを入力して「接続」。ペアリング後に表示されるホストの指紋が、Windows 側に表示されている指紋と一致することを確認してください。2 回目以降はコード不要です。

- ⌘ は既定で **Ctrl** として送ります（⌘C / ⌘V でコピー・貼り付け）。チェックを外すと Windows キーになります。
- ⌘Q（終了）と ⌘N（新しい接続）は Mac 側で使います。メニュー「リモート」から Windows キー、Ctrl+Shift+Esc、Alt+Tab を送れます。
- JIS キーボードの「英数」「かな」は IME オフ / オンとして送ります。キーは物理位置（スキャンコード）で送ります。

## 仕組み

```
Sources/
  RDCore/
    Security/  Noise XX、暗号化ストリーム、ペアリング、認証、鍵の保管 (DPAPI / キーチェーン)
    ...        メッセージ、ソケット (Winsock / BSD)、タイル差分コーデック
  RDHost/      Windows: GDI キャプチャ + SendInput + 承認ダイアログ（Windows 以外ではテストパターン配信）
  RDViewer/    macOS: AppKit ビューア（--headless で GUI なしの受信テスト）
```

- 画面を 64×64 のタイルに分け、変化したタイルだけを RLE（24bit 色）で送ります。
- ビューアがフレームを処理し終えたら ACK を返し、ホストはそれを待ってから次を送るので、遅い回線でも遅延が溜まりません。

### 動作確認（Windows / Mac がなくても）

Windows 以外で `RDHost` を動かすとテストパターンを配信し、受け取った入力をログに出します。

```bash
swift run -c release RDHost --port 6001 --pair
```

```bash
swift run -c release RDViewer --headless 127.0.0.1 6001 --pair <表示されたコード> --frames 90
```

```bash
swift test
```

## 制限

- プライマリモニタのみ。音声・クリップボード共有・ファイル転送なし。
- ロック画面や UAC の確認画面は（Windows の仕様上）キャプチャ・操作できません。Ctrl+Alt+Del も送れません。
- 圧縮は簡易 RLE なので、動画など変化の多い画面は帯域を多く使います（`--scale 2` で軽くなります）。
