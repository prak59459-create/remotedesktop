// WinHTTP (winhttp.h) は Swift の WinSDK モジュールに含まれないので、ここで読み込む。
// Windows 以外では空。
#pragma once
#if defined(_WIN32)
#include <windows.h>
#include <winhttp.h>
#endif
