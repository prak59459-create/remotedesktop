// RemoteDesktopHost.exe: ホストの GUI 版 (ウィンドウとタスクトレイ)。本体は RDHostKit。
#if os(Windows)
runApp()
#else
print("RemoteDesktopHost (GUI 版) は Windows 専用です。ほかの OS では RDHost (コマンドライン版) を使ってください。")
#endif
