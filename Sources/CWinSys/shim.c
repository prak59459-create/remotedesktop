// CWinSys: Swift の WinSDK に含まれない Windows API のための C ターゲット
#include "CWinSys.h"

#if defined(_WIN32)
#include <windns.h>

// DnsServiceRegister は Windows 10 1809 以降にしか無いので、リンクせずに実行時に探す
// (古い Windows でも EXE 自体は起動できるように)。
typedef PDNS_SERVICE_INSTANCE (WINAPI *ConstructInstanceFn)(PCWSTR, PCWSTR, PIP4_ADDRESS, PIP6_ADDRESS,
                                                            WORD, WORD, WORD, DWORD, PCWSTR *, PCWSTR *);
typedef DWORD (WINAPI *ServiceRegisterFn)(PDNS_SERVICE_REGISTER_REQUEST, PDNS_SERVICE_CANCEL);
typedef VOID (WINAPI *FreeInstanceFn)(PDNS_SERVICE_INSTANCE);

static FreeInstanceFn g_free;
static DNS_SERVICE_REGISTER_REQUEST g_request; // 公開している間は保持しておく

static VOID WINAPI rd_mdns_done(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
    (void)status;
    (void)context;
    if (instance && g_free) g_free(instance);
}

unsigned long rd_mdns_register(const wchar_t *instanceName, const wchar_t *hostName,
                               unsigned long ip4, unsigned short port) {
    HMODULE dll = LoadLibraryW(L"dnsapi.dll");
    if (!dll) return GetLastError();
    ConstructInstanceFn construct = (ConstructInstanceFn)(void *)GetProcAddress(dll, "DnsServiceConstructInstance");
    ServiceRegisterFn reg = (ServiceRegisterFn)(void *)GetProcAddress(dll, "DnsServiceRegister");
    g_free = (FreeInstanceFn)(void *)GetProcAddress(dll, "DnsServiceFreeInstance");
    if (!construct || !reg) return ERROR_PROC_NOT_FOUND;

    IP4_ADDRESS addr = (IP4_ADDRESS)ip4;
    PDNS_SERVICE_INSTANCE inst = construct(instanceName, hostName, ip4 ? &addr : NULL, NULL, port, 0, 0, 0, NULL, NULL);
    if (!inst) return ERROR_OUTOFMEMORY;

    ZeroMemory(&g_request, sizeof(g_request));
    g_request.Version = DNS_QUERY_REQUEST_VERSION1;
    g_request.InterfaceIndex = 0; // すべてのネットワーク
    g_request.pServiceInstance = inst;
    g_request.pRegisterCompletionCallback = rd_mdns_done;
    DWORD rc = reg(&g_request, NULL);
    return rc == DNS_REQUEST_PENDING ? 0 : rc;
}
#endif
