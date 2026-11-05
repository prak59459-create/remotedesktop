import Foundation
import RDCore

// RDViewer: Windows で動いている RDHost に接続して操作する
//
//   RDViewer                    … 接続ダイアログを開く (macOS)
//   RDViewer <host> [port]      … すぐ接続 (macOS)
//   RDViewer --headless <host>  … GUI なしで受信テスト

let arguments = Array(CommandLine.arguments.dropFirst())

#if os(macOS)
if arguments.contains("--headless") {
    runHeadless(arguments)
} else {
    runMacApp(arguments)
}
#else
runHeadless(arguments)
#endif
