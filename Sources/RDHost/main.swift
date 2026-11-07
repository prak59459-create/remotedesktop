import Foundation
import RDCore
import RDHostKit

// RDHost: 画面を配信し、ビューアからの入力を受け付ける (Windows 用)
//
// 通信はすべて Noise (X25519 + ChaCha20-Poly1305、対応端末では ML-KEM-768 も併用) で
// 暗号化・相互認証され、ペアリング済みの端末だけが接続できる。

func usage() -> Never {
    print("""
    使い方: RDHost [オプション]

    起動:
      --pair            新しい端末を登録するためのペアリングコードを表示 (10 分間・1 回限り有効)
                        登録は同じ LAN (Wi-Fi) から直接つないだときだけ受け付ける
      --relay URL       中継サーバー経由でも待ち受ける (例: https://xxxx.onrender.com)
                        ルーターのポート開放は不要。中継サーバーには暗号文しか流れない
      --relay-transport M  中継サーバーへの通り道: auto (既定) / websocket / http
                        auto は WebSocket を試し、つながらなければ普通の HTTP リクエストに切り替える
                        (WebSocket を通さないプロキシや社内ネットワークでは http を指定)
      --no-direct       直接接続 (TCP) の待ち受けをしない (中継のみ)
      --no-bonjour      同じ Wi-Fi の iPad に、この PC の名前を知らせない (IP アドレスで接続する)
      --allow-remote-pairing  LAN 外 (中継経由・インターネット) からの端末登録も許可する (非推奨)
      --confirm         登録済みの端末でも、接続のたびにこの PC の画面で許可/拒否を確認する
                        (新しい端末の登録はこの指定にかかわらず必ず確認する)
      --on-disconnect M 最後の接続が切れたときの画面: blank (モニター消灯・既定) / lock / none
      --idle-timeout N  操作が N 分なければ切断 (既定 15)
      --max-session N   1 回の接続の最長時間 (時間、既定 8)
      --require-pq      耐量子暗号 (ML-KEM) に対応していない端末を拒否する
      --allow-admin     管理者権限での起動を許可する (非推奨)
      --bind ADDR       待ち受けるアドレス (例: 192.168.0.10)。既定は全インターフェース
      --port N          待ち受けポート (既定 \(defaultPort))
      --fps N           最大フレームレート (既定 30)
      --scale N         縮小率。2 なら縦横 1/2 で送信 (既定 1)
      --max-kbps N      画面データの送信量の上限 (kbps)。無料の中継サーバーの月間転送量を守るとき (例: 500)

    端末の管理:
      --list            登録済みの端末を表示
      --revoke ID       端末の登録を取り消す (ID は --list の指紋の先頭 4 文字以上)
      --fingerprint     このホストの指紋を表示
      --reset-devices   登録済み端末をすべて消す (一覧の改ざんを検知したときの復旧用)
      --verify-log      監査ログのハッシュチェーンを検証する
    """)
    exit(0)
}

enum Command: Equatable { case serve, list, revoke(String), fingerprint, resetDevices, verifyLog }

var options = HostOptions()
var command = Command.serve
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--port": options.port = args.next().flatMap { UInt16($0) } ?? options.port
    case "--bind": options.bindAddress = args.next()
    case "--fps": options.fps = min(60, max(1, args.next().flatMap { Double($0) } ?? options.fps))
    case "--scale": options.scale = min(8, max(1, args.next().flatMap { Int($0) } ?? options.scale))
    case "--max-kbps": options.maxKbps = max(0, args.next().flatMap { Double($0) } ?? 0)
    case "--pair": options.pair = true
    case "--confirm": options.confirm = true
    case "--relay":
        guard let u = args.next().flatMap(URL.init(string:)), ["https", "wss", "http", "ws"].contains(u.scheme ?? "") else {
            print("--relay には https:// で始まる URL を指定してください")
            exit(1)
        }
        options.relay = u
    case "--relay-transport":
        guard let m = args.next().flatMap(RelayTransportMode.init(rawValue:)) else {
            print("--relay-transport には auto / websocket / http のどれかを指定してください")
            exit(1)
        }
        RelayTransportMode.default = m
    case "--no-direct": options.direct = false
    case "--no-bonjour": options.bonjour = false
    case "--allow-remote-pairing": options.allowRemotePairing = true
    case "--on-disconnect":
        guard let a = args.next().flatMap(DisconnectAction.init(rawValue:)) else {
            print("--on-disconnect には blank / lock / none のどれかを指定してください")
            exit(1)
        }
        options.onDisconnect = a
    case "--idle-timeout": options.idleTimeout = max(1, args.next().flatMap { Double($0) } ?? 15) * 60
    case "--max-session": options.maxSession = max(0.1, args.next().flatMap { Double($0) } ?? 8) * 3600
    case "--require-pq": options.requirePostQuantum = true
    case "--allow-admin": options.allowAdmin = true
    case "--reset-devices": command = .resetDevices
    case "--verify-log": command = .verifyLog
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

if command == .verifyLog {
    switch AuditLog.verify() {
    case .ok(let n): print("監査ログは改ざんされていません (\(n) 行)"); exit(0)
    case .broken(let line): print("⚠️ 監査ログの \(line) 行目以降が改ざん・削除されています"); exit(2)
    case .missing: print("監査ログがありません"); exit(0)
    }
}

let service: HostService
do {
    service = try HostService(options: options)
} catch {
    print("エラー: 鍵を読み込めません: \(error)")
    exit(1)
}
if service.isTampered && command != .resetDevices {
    print("⚠️ 許可端末の一覧が改ざんされています。すべての接続を拒否します。")
    print("   心当たりがなければ PC の安全を確認したうえで RDHost --reset-devices を実行し、端末をペアリングし直してください。")
}

switch command {
case .fingerprint:
    print(service.fingerprint)
    exit(0)
case .list:
    let all = service.devices
    if all.isEmpty { print("登録済みの端末はありません") }
    for d in all {
        print("\(d.fingerprint)  \(d.name)  登録: \(d.added)  最終接続: \(d.lastSeen.map { "\($0)" } ?? "-")")
    }
    exit(0)
case .revoke(let q):
    do {
        let n = try service.revoke(q)
        print(n > 0 ? "\(n) 件の端末を取り消しました" : "一致する端末がありません (4 文字以上指定してください)")
        exit(n > 0 ? 0 : 1)
    } catch {
        print("エラー: \(error)")
        exit(1)
    }
case .resetDevices:
    do {
        try service.resetDevices()
        print("登録済み端末をすべて消しました。RDHost --pair で端末をペアリングし直してください。")
        exit(0)
    } catch {
        print("エラー: \(error)")
        exit(1)
    }
case .verifyLog:
    exit(0)
case .serve:
    break
}

if let problem = HostService.environmentProblem(allowAdmin: options.allowAdmin) {
    print("⚠️ \(problem)")
    print("   (どうしても必要な場合は --allow-admin)")
    exit(1)
}

HostService.setupPlatform()
#if !os(Windows)
// 同じ PC 内での自動テスト用 (Windows 版には無い)
if ProcessInfo.processInfo.environment["RD_TEST_LOOPBACK_IS_LAN"] == "1" { TCPConnection.treatLoopbackAsLAN = true }
#endif

do {
    try service.start()
} catch {
    print("エラー: \(error)")
    exit(1)
}

print("ホストの指紋: \(service.fingerprint)")
print("登録済み端末: \(service.devices.count) 台\(options.confirm ? " / 接続時に確認あり" : "")")
print("無操作 \(Int(options.idleTimeout / 60)) 分で切断 / 切断時: \(options.onDisconnect.rawValue)\(options.requirePostQuantum ? " / 耐量子暗号必須" : "")")
if options.pair {
    let w = service.startPairing()
    print("""

    ┌──────────────────────────────────────────────┐
      ペアリングコード:  \(w.code)
      (10 分間・1 回限り有効。他人に見せないでください)
      \(options.allowRemotePairing ? "※ LAN 外からの登録も許可しています" : "iPad / Mac を同じ Wi-Fi につないで、この PC の IP アドレスに直接接続してください")
    └──────────────────────────────────────────────┘

    """)
} else if service.devices.isEmpty {
    print("※ 端末が未登録です。RDHost --pair で起動し、同じ Wi-Fi からペアリングしてください。")
}

// 待ち受けは別スレッド。このスレッドは終了しないように待つ
while true { Thread.sleep(forTimeInterval: 3600) }
