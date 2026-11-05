// Swift の WinSDK モジュールに含まれない Windows のヘッダーをここで読み込む。
//   winhttp.h: 中継サーバーへの WebSocket (TLS)
//   ncrypt.h:  TPM (Microsoft Platform Crypto Provider) による鍵の保護
// Windows 以外では空。
#pragma once
#if defined(_WIN32)
#include <windows.h>
#include <winhttp.h>
#include <ncrypt.h>
#endif
