# 中継サーバーを自分で動かす

Render の無料プランの代わりに、自分の VPS（月数百円程度）で中継サーバーを動かす手順です。
中継サーバーは暗号文を受け渡すだけなので、どこで動かしても通信の中身は守られます。自前にする利点は、**接続の時刻・量・IP アドレスを第三者（Render）に見られない**ことです。

## 必要なもの

- Linux の VPS（Docker が動くもの）
- 独自ドメイン（例: `relay.example.com`）と、その A レコードを VPS に向けたもの
- 開けるポートは **443 だけ**（80 は証明書の取得に一時的に使う）

## 手順

1. このリポジトリの `relay/` を VPS にコピーし、イメージを作る

```bash
docker build -t rd-relay ./relay
```

2. 中継サーバーを起動する（外には公開せず、同じ VPS の Caddy からだけ使う）

```bash
docker run -d --name rd-relay --restart unless-stopped --read-only --cap-drop ALL --security-opt no-new-privileges -e TRUST_PROXY=1 -p 127.0.0.1:8080:8080 rd-relay
```

3. Caddy で TLS（Let's Encrypt の証明書を自動取得）を付ける。`/etc/caddy/Caddyfile`:

```
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

4. RDHost と iPad アプリの中継サーバー URL を `https://relay.example.com` にする

## 運用

- `docker logs rd-relay` に 10 分ごとの統計（トークン不一致・レート制限・帯域超過の回数）が出ます。急に増えたら攻撃の兆候です。
- 帯域の上限は環境変数 `ROOM_BYTES_PER_SECOND`（既定 8 MB/s）と `ROOM_BURST_BYTES` で変えられます。
- `npm audit` と Dependabot の更新を取り込んだら、イメージを作り直してください。
