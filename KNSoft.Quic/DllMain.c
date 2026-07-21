#include "../precomp.h"

BOOL
WINAPI
DllMain(
    _In_ HMODULE DllHandle,
    _In_ DWORD Reason,
    _In_opt_ LPVOID Reserved)
{
    UNREFERENCED_PARAMETER(Reserved);

    if (Reason == DLL_PROCESS_ATTACH)
    {
#ifndef _MT
        DisableThreadLibraryCalls(DllHandle);
#else
        UNREFERENCED_PARAMETER(DllHandle);
#endif
        MsQuicLibraryLoad();
    } else if (Reason == DLL_PROCESS_DETACH)
    {
        MsQuicLibraryUnload();
    }

    return TRUE;
}
