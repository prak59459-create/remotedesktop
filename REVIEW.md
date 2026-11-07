# セキュリティレビューのお願い（検査する人・AI 向け）

このリポジトリはリモートデスクトップ（Windows ホスト ← iPad / Mac ビューア）です。脅威モデルと設計は [SECURITY.md](SECURITY.md) にあります。ここには **特に見てほしい場所** と **確かめ方** をまとめます。

## 信頼境界

1. **ネットワーク上の誰か**（中継サーバー含む）→ ホスト / ビューアの受信処理。認証前に触れる部分が最重要。
2. **認証済みだが悪意あるホスト** → ビューア（画面データのデコード）。
3. **認証済みのビューア** → ホスト（入力注入。認証済みなら操作できるのは仕様）。
4. **ディスク上のファイル**（鍵・許可一覧）。

## 重点的に見てほしい箇所

| ファイル | 内容 | 観点 |
|---|---|---|
| `Sources/RDCore/Security/Noise.swift` | Noise XX の実装 | 仕様との一致（cacophony のテストベクタで確認済み）、nonce の扱い、DH 結果の検証、状態遷移の誤用 |
| `Sources/RDCore/Security/SecureStream.swift` | 暗号化レコード層 | 長さの扱い、復号失敗時の処理、分割・再結合 |
| `Sources/RDCore/Security/Auth.swift` | 認証・ペアリング・レート制限・LAN 限定 | 認証前に資源を食わせられないか、ペアリング証明の結び付け、`isLocalNetwork` の判定、TOCTOU、拒否時の情報漏えい |
| `Sources/RDCore/Security/Identity.swift` | ペアリングコード・指紋・Base32 | 指紋 80bit + 秘密 40bit の強度の妥当性、比較の定数時間性 |
| `Sources/RDCore/Security/Storage.swift` | DPAPI / キーチェーン / ファイル権限 / 監査ログ | 権限、原子的書き込み、ログインジェクション |
| `Sources/RDCore/TileCodec.swift` | 画面データのデコード（RLE24・パレット・HALF565） | 境界チェック（悪意あるホスト → ビューアのメモリ破壊がないか）、パレットの索引の範囲、HALF565 の端の画素 |
| `Sources/RDCore/Protocol.swift`, `Bytes.swift` | メッセージの解析 | 長さ・範囲の検証 |
| `Sources/RDCore/WebSocket.swift` | WebSocket クライアント 3 種 | 最小実装（Linux 用）のフレーム解析、WinHTTP の TLS 設定 |
| `Sources/RDCore/Relay.swift` | 中継経由の待ち受け、WebSocket と HTTP の切り替え | 中継サーバーからの制御メッセージを信用していないか |
| `Sources/RDCore/HTTPRelay.swift`, `HTTPClient.swift` | HTTP だけで中継する通り道 | 下りフレームの長さ上限、ストリーム→ポーリング切り替えでの取りこぼし、最小実装（Linux 用）の chunked 解析、WinHTTP のハンドルを使用中に閉じないか |
| `Sources/RDCore/Socket.swift` | ソケット | `close()` は shutdown のみ・解放は deinit（使用中の番号の再利用を防ぐ） |
| `relay/server.js` | 中継サーバー | DoS 耐性、部屋の乗っ取り、セッション ID・leg の扱い、`X-Forwarded-For`、HTTP の通し番号と掃除 |
| `Sources/RDCore/Security/PostQuantum.swift` | ML-KEM-768 のハイブリッド鍵交換 | 鍵の混ぜ方、交渉のダウングレード耐性 |
| `Sources/RDCore/Security/DeviceKeyProtection.swift` | iPad の Secure Enclave・Face ID | アクセス制御フラグ、フォールバック時の弱さ |
| `Sources/RDCore/Security/Storage.swift`（TPMWrap・TrustStore・AuditLog） | TPM での鍵の保護、許可一覧の HMAC、監査ログのハッシュチェーン | 古い形式への差し替え、移行時の扱い |
| `Sources/RDHost/WindowsPlatform.swift` | GDI キャプチャ・SendInput・承認ダイアログ・接続中の表示・画面消灯・権限確認・イベントログ | |
| `Sources/RDFuzz/main.swift`, `scripts/fuzz.sh` | ファジングの対象範囲 | 抜けている解析部分がないか |
| `.github/workflows/` | CI・出どころ証明・CodeQL | 権限の最小化、SHA 固定 |

## 既に分かっている設計上の割り切り

SECURITY.md の「既知の限界」を参照してください（第三者監査なし、ホスト PC が侵害されたら守れない、監査ログは改ざん可能、中継運営者にはメタデータが見える、など）。

## 確かめ方

```bash
swift test
```

```bash
cd relay && npm ci && npm test && npm audit
```

- `swift test` には Noise の公式テストベクタ、改ざん検知、MITM 検知、ペアリングの使い捨て・回数制限・LAN 限定・画面での許可、失効、耐量子の交渉、再鍵交換、許可一覧の改ざん検知、監査ログの検証、中継経由の通し試験（Node があれば）が含まれます。
- `scripts/fuzz.sh 秒数` で libFuzzer + AddressSanitizer のファジング（Linux）。CI で毎回 5 分、毎晩 1 時間。
- 手で試す場合は README の「動作確認」を見てください（Windows / Mac がなくても Linux でテストパターン配信できます）。

## これまでの自己レビュー（2026-11-05、Claude による。第三者レビューの代わりではありません）

コードレビューの手順（行ごとの確認・削除された処理の確認・呼び出し元の追跡など 8 観点）で 10 件見つけ、すべて修正して回帰テストを追加しました。

| 重大度 | 内容 | 対応 |
|---|---|---|
| High | 改ざん検知の鍵ファイルだけを消すと、署名のない許可一覧が受け入れられる | 鍵をホストの秘密鍵から導出。署名のない一覧は常に拒否 |
| High | 別プロセスでの `--revoke` が、ホストの古い一覧の書き込みで取り消される | 書き込み前に必ず読み直す |
| Medium | WinHTTP のハンドルを閉じた後に送受信しうる | 状態を管理し、使用中は閉じない |
| Medium | 複数プロセスが監査ログに書くとチェーンが分岐し、誤って改ざん扱い | ファイル末尾から直前のハッシュを読む |
| Medium | トンネル経由（127.0.0.1）の接続が LAN 扱いになり、LAN 限定の登録を迂回 | ループバックを LAN から除外 |
| Low | 中継の受信バッファが詰められず増え続ける | 1 MB ごとに詰める |
| Low | Face ID 再登録後に復旧手段がない | 「端末の鍵をリセット」を追加 |
| Low | 画面で拒否してもペアリングコードが消費される | 許可後に使用済みにする |
| Low | 答えのない確認ダイアログの後ろに接続が溜まる | 同時に 1 つ、60 秒で自動拒否 |
| Low | 同じトークンのホストが 2 つあると中継で追い出し合う | 先に来た方を優先 |

## 報告してほしい形式

重大度（Critical / High / Medium / Low）、該当ファイルと行、再現手順または攻撃シナリオ、修正案。
