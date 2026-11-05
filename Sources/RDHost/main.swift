import Foundation
import RDCore

// RDHost: 画面を配信し、ビューアからの入力を受け付ける (Windows 用)
//
// 通信はすべて Noise (X25519 + ChaCha20-Poly1305) で暗号化・相互認証され、
// ペアリング済みの端末だけが接続できる。

func usage() -> Never {
    print("""
    使い方: RDHost [オプション]

    起動:
      --pair            新しい端末を登録するためのペアリングコードを表示 (10 分間・1 回限り有効)
      --confirm         接続のたびに、この PC の画面で許可/拒否を確認する
      --bind ADDR       待ち受けるアドレス (例: 192.168.0.10)。既定は全インターフェース
      --port N          待ち受けポート (既定 \(defaultPort))
      --fps N           最大フレームレート (既定 30)
      --scale N         縮小率。2 なら縦横 1/2 で送信 (既定 1)

    端末の管理:
      --list            登録済みの端末を表示
      --revoke ID       端末の登録を取り消す (ID は --list の指紋の先頭 4 文字以上)
      --fingerprint     このホストの指紋を表示
    """)
    exit(0)
}

enum Command { case serve, list, revoke(String), fingerprint }

var options = HostOptions()
var command = Command.serve
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--port": options.port = args.next().flatMap { UInt16($0) } ?? options.port
    case "--bind": options.bindAddress = args.next()
    case "--fps": options.fps = min(60, max(1, args.next().flatMap { Double($0) } ?? options.fps))
    case "--scale": options.scale = min(8, max(1, args.next().flatMap { Int($0) } ?? options.scale))
    case "--pair": options.pair = true
    case "--confirm": options.confirm = true
    case "--list": command = .list
    case "--revoke": command = .revoke(args.next() ?? "")
    case "--fingerprint": command = .fingerprint
    case "--data-dir": DataDirectory.overridePath = args.next()
    case "-h", "--help": usage()
    default:
        print("不明な引数: \(a)")
        usage()
    }
}

#if !os(Windows)
setvbuf(stdout, nil, _IONBF, 0)
#endif

let identity: StaticIdentity
let clients: TrustStore
do {
    identity = try SecretStore.loadOrCreateIdentity(name: "host_identity")
    clients = try TrustStore(fileName: "authorized_devices.json")
} catch {
    print("エラー: 鍵を読み込めません: \(error)")
    exit(1)
}

switch command {
case .fingerprint:
    print(identity.fingerprint)
    exit(0)
case .list:
    let all = clients.all
    if all.isEmpty { print("登録済みの端末はありません") }
    for e in all {
        let fp = Fingerprint.fromHex(e.publicKey).map(Fingerprint.display) ?? "?"
        print("\(fp)  \(e.name)  登録: \(e.added)  最終接続: \(e.lastSeen.map { "\($0)" } ?? "-")")
    }
    exit(0)
case .revoke(let q):
    do {
        let n = try clients.remove(matching: q)
        print(n > 0 ? "\(n) 件の端末を取り消しました" : "一致する端末がありません (4 文字以上指定してください)")
        if n > 0 { AuditLog().record("DEVICE_REVOKED query=\(q) count=\(n)") }
        exit(n > 0 ? 0 : 1)
    } catch {
        print("エラー: \(error)")
        exit(1)
    }
case .serve:
    break
}

platformSetup()
let audit = AuditLog()
let gate = HostGatekeeper(identity: identity, clients: clients, audit: audit)
if options.confirm {
    let consentLock = NSLock() // ダイアログは 1 つずつ
    gate.consent = { name, fp, peer, isNew in
        consentLock.lock(); defer { consentLock.unlock() }
        return askConsent(name: name, fingerprint: fp, peer: peer, isNew: isNew)
    }
}

let listener: TCPListener
do {
    listener = try TCPListener(port: options.port, bindAddress: options.bindAddress)
} catch {
    print("エラー: \(error)")
    exit(1)
}

print("RDHost 待ち受け中: \(options.bindAddress ?? "0.0.0.0"):\(options.port)")
print("ホストの指紋: \(identity.fingerprint)")
print("登録済み端末: \(clients.all.count) 台\(options.confirm ? " / 接続時に確認あり" : "")")
if options.pair {
    let w = gate.startPairing()
    print("""

    ┌──────────────────────────────────────────────┐
      ペアリングコード:  \(w.code.string)
      (10 分間・1 回限り有効。他人に見せないでください)
    └──────────────────────────────────────────────┘

    """)
} else if clients.all.isEmpty {
    print("※ 端末が未登録です。RDHost --pair で起動してペアリングしてください。")
}
audit.record("HOST_START port=\(options.port) pairing=\(options.pair) confirm=\(options.confirm)")

while true {
    do {
        let conn = try listener.accept()
        Thread {
            do {
                let client = try gate.authenticate(conn)
                HostSession(client: client, gate: gate, options: options, audit: audit).run()
            } catch {
                // 理由は監査ログに記録済み
            }
        }.start()
    } catch {
        print("accept エラー: \(error)")
        Thread.sleep(forTimeInterval: 0.5)
    }
}
