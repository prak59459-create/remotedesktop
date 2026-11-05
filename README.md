# remotedesktop

SwiftPM で作ったリモートデスクトップです。**iPad（または Mac）から Windows の画面を見て操作**します。
通信はすべて**端末間で暗号化・相互認証**され、**ペアリングした端末だけ**が接続できます。外出先からは**ポート開放なしの中継サーバー経由**で使えます。

| | 動かす場所 | 役割 |
|---|---|---|
| `RDHost.exe` | **Windows**（操作される側） | 画面キャプチャを配信し、受け取った入力を注入 |
| `ipad/RemoteDesktop.swiftpm` | **iPad / iPhone**（操作する側） | Swift Playgrounds で開くアプリ |
| `RDViewer` | **macOS**（操作する側） | Mac 用ビューア |
| `relay/` | **無料の Render など** | 外出先用の中継サーバー（暗号文を受け渡すだけ） |

## セキュリティの概要（詳細は [SECURITY.md](SECURITY.md)、検査する人向けは [REVIEW.md](REVIEW.md)）

- **Noise Protocol（`Noise_XX_25519_ChaChaPoly_SHA256`）**で暗号化と相互認証。平文モードなし。対応端末では**耐量子暗号 ML-KEM-768** も併用し、長いセッションでは定期的に鍵を更新。
- **パスワードなし。** 端末ごとの鍵で認証し、ホストは登録済みの端末だけを受け入れます。
- **ペアリングコード**にホストの指紋が入っているので、初回でもなりすましを自動で検出。コードは 1 回限り・10 分で失効・5 回間違えると無効。**登録は同じ Wi-Fi からだけ、かつ Windows の画面での許可が必須**。
- **iPad の鍵は Secure Enclave で守り、接続のたびに Face ID**。なくした iPad からは接続できません。
- **中継サーバーは中身を読めません。** ホストは外向きに接続するだけなので、自宅のルーターで**ポートを開ける必要がありません**。
- Windows の秘密鍵は TPM + DPAPI で保護。許可端末の一覧は改ざん検知つき、監査ログはハッシュチェーン（Windows イベントログにも記録）。総当たり対策、端末の失効（接続中も即切断）。
- 接続中は Windows の画面上部に赤い帯を表示。無操作 15 分で切断、切断後はモニター消灯。管理者権限では起動しない。
- 配布する EXE には GitHub の**出どころ証明**と SHA-256 を付け、解析部分は継続的にファジング。

> 第三者のセキュリティ監査は受けていません。限界は SECURITY.md の「既知の限界」を見てください。

## 使い方

### 1. 中継サーバー（外出先から使う場合・最初に一度だけ）

[Render](https://render.com) の無料プランで動かします。このリポジトリの `render.yaml`（Blueprint）からデプロイすると `https://<名前>.onrender.com` が中継サーバーの URL になります。

### 2. Windows 側 (RDHost.exe)

GitHub Actions の `build` ワークフローの成果物 **`RDHost-windows-x64`** をダウンロードし、フォルダごと置きます（自分でビルドする場合は `scripts\build-windows.ps1`）。

ダウンロードしたものが GitHub Actions で作られた本物か確かめるには（[GitHub CLI](https://cli.github.com/) が必要）:

```bash
gh attestation verify RDHost.exe -R prak59459-create/remotedesktop
```

**通常のユーザー（管理者ではない）で起動してください。**

**初回**は、iPad と同じ Wi-Fi で `--pair` 付きで起動します:

```bash
RDHost.exe --pair --relay https://<名前>.onrender.com
```

表示された**ペアリングコード**と、PC の IP アドレスを iPad に入力します。2 回目以降は `--pair` なしで起動します:

```bash
RDHost.exe --relay https://<名前>.onrender.com --confirm
```

| オプション | 説明 |
|---|---|
| `--pair` | 新しい端末を登録するためのコードを表示（同じ Wi-Fi からのみ。登録時は画面で許可） |
| `--relay URL` | 中継サーバー経由でも待ち受ける（ポート開放不要） |
| `--no-direct` | 直接接続（TCP 5999）の待ち受けをしない |
| `--confirm` | 登録済みの端末でも、接続のたびに Windows 側で許可/拒否のダイアログを出す（外出先で使うなら付けない） |
| `--on-disconnect blank/lock/none` | 最後の接続が切れたときの画面（既定: モニター消灯） |
| `--idle-timeout 分` / `--max-session 時間` | 無操作で切断するまでの時間（既定 15 分）/ 最長時間（既定 8 時間） |
| `--require-pq` | 耐量子暗号に対応していない端末（iPadOS 26 未満）を拒否 |
| `--bind ADDR` / `--port N` / `--fps N` / `--scale N` | 待ち受けアドレス、ポート、最大フレームレート、縮小率 |
| `--list` / `--revoke ID` / `--fingerprint` | 登録済み端末の一覧 / 取り消し / ホストの指紋 |
| `--verify-log` / `--reset-devices` | 監査ログの改ざん検証 / 登録端末をすべて消去（一覧の改ざんを検知したとき） |
| `--allow-remote-pairing` | LAN 外からの端末登録も許可（非推奨） |

ポート開放は**不要**です（中継モード）。直接接続をインターネットに公開したい場合でも、ペアリングは LAN 内からしか受け付けません。

### 3. iPad 側

1. このリポジトリの `ipad/RemoteDesktop.swiftpm` フォルダを iPad の「ファイル」に入れ（iCloud Drive など）、**Swift Playgrounds** で開いて実行します。
2. **初回**: 「同じ Wi-Fi」を選び、PC の IP アドレスとペアリングコードを入力して「接続」。Windows 側に出る確認ダイアログで「はい」を押し、iPad に表示されたホストの指紋が Windows 側の表示と同じか確認します。
3. **外出先**: 「外出先 (中継)」を選び、中継サーバーの URL を入力して「接続」。中継の設定（部屋 ID）は初回の接続で自動的に受け取ってあります。
4. 接続のたびに Face ID を求められます（Face ID を登録し直したら、もう一度ペアリングが必要です）。

操作（トラックパッド方式）:
- 1 本指で動かす: カーソル移動 / タップ: 左クリック / 2 本指タップ: 右クリック
- 2 本指で上下: スクロール / 長押ししてから動かす: ドラッグ
- マウスやトラックパッドを iPad につないだ場合はポインタに追従、右クリックも可
- ハードウェアキーボードはそのまま使えます（⌘ は Ctrl として送る設定が既定）。⌨️ で画面キーボード、文字入力ボタンで日本語などを確定してまとめて送れます

### 4. Mac 側（任意）

```bash
swift run -c release RDViewer
```

## 仕組み

```
Sources/
  RDCore/
    Security/  Noise XX、暗号化ストリーム、ペアリング、認証、鍵の保管 (DPAPI / キーチェーン)
    Relay / WebSocket / Transport   中継経由の接続 (URLSession / WinHTTP / 最小実装)
    ...        メッセージ、ソケット (Winsock / BSD)、タイル差分コーデック
  RDHost/      Windows: GDI キャプチャ + SendInput + 承認ダイアログ（Windows 以外ではテストパターン配信）
  RDViewer/    macOS: AppKit ビューア（--headless で GUI なしの受信テスト）
ipad/RemoteDesktop.swiftpm/
  App/         iPad アプリ (SwiftUI + UIKit)
  Core/        Sources/RDCore のコピー (scripts/sync-ipad.sh で更新。直接編集しない)
relay/         中継サーバー (Node.js + ws)
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

中継経由も試す場合:

```bash
cd relay && npm ci && PORT=8099 node server.js
```

```bash
swift run -c release RDHost --port 6001 --pair --relay ws://127.0.0.1:8099
```

（ペアリングは直接接続で行い、その後 `RDViewer --headless --relay ws://127.0.0.1:8099 --frames 90` で中継経由になります）

## 制限

- プライマリモニタのみ。音声・クリップボード共有・ファイル転送なし。
- ロック画面や UAC の確認画面は（Windows の仕様上）キャプチャ・操作できません。Ctrl+Alt+Del も送れません。
- 圧縮は簡易 RLE なので、動画など変化の多い画面は帯域を多く使います（`--scale 2` や `--fps 15` で軽くなります）。無料の中継サーバーは月間の転送量に上限があります。
- iPad アプリは Swift Playgrounds での実行を想定しています（App Store 配布はしていません）。
