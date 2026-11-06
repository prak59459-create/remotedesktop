// Swift の WinSDK モジュールに含まれない Windows のヘッダーをここで読み込む。
//   winhttp.h: 中継サーバーへの WebSocket (TLS)
//   ncrypt.h:  TPM (Microsoft Platform Crypto Provider) による鍵の保護
//   rd_mdns_*: 同じ LAN の iPad から見つけてもらうための DNS-SD (Bonjour) 公開 (shim.c)
// Windows 以外では空。
#pragma once
#if defined(_WIN32)
#include <windows.h>
#include <winhttp.h>
#include <ncrypt.h>

/// DNS-SD (Bonjour) でサービスを公開する。Windows 10 1809 以降の DnsServiceRegister を実行時に読み込む。
/// instanceName: "名前._rdhost._tcp.local"、hostName: "名前.local"、ip4: ネットワークバイトオーダー (0 なら省略)。
/// 戻り値: 0 = 受け付けた、それ以外 = Win32 エラー (古い Windows では ERROR_PROC_NOT_FOUND)。
unsigned long rd_mdns_register(const wchar_t *instanceName, const wchar_t *hostName,
                               unsigned long ip4, unsigned short port);
#endif
