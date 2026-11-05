import Foundation
import RDCore

// RDHost: 画面を配信し、ビューアからの入力を受け付ける (Windows 用)
//
//   RDHost.exe [--port 5999] [--fps 30] [--scale 1]
//
// ※ 認証・暗号化はありません。信頼できる LAN 内だけで使ってください。

func usage() -> Never {
    print("""
    使い方: RDHost [--port N] [--fps N] [--scale N]
      --port   待ち受けポート (既定 \(defaultPort))
      --fps    最大フレームレート (既定 30)
      --scale  縮小率。2 なら縦横 1/2 で送信 (既定 1)
    """)
    exit(0)
}

var options = HostOptions()
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--port": options.port = args.next().flatMap { UInt16($0) } ?? options.port
    case "--fps": options.fps = args.next().flatMap { Double($0) } ?? options.fps
    case "--scale": options.scale = max(1, args.next().flatMap { Int($0) } ?? options.scale)
    case "-h", "--help": usage()
    default:
        print("不明な引数: \(a)")
        usage()
    }
}

#if !os(Windows)
setvbuf(stdout, nil, _IONBF, 0)
#endif
platformSetup()

let listener: TCPListener
do {
    listener = try TCPListener(port: options.port)
} catch {
    print("エラー: \(error)")
    exit(1)
}
print("RDHost 待ち受け中: ポート \(options.port) (fps=\(options.fps), scale=\(options.scale))")
print("⚠️ 認証・暗号化なし。信頼できるネットワークでのみ使用してください。")

while true {
    do {
        let conn = try listener.accept()
        let session = HostSession(connection: conn, options: options)
        Thread { session.run() }.start()
    } catch {
        print("accept エラー: \(error)")
        Thread.sleep(forTimeInterval: 0.5)
    }
}
