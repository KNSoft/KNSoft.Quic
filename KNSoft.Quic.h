#pragma once

#define QUIC_API_ENABLE_INSECURE_FEATURES 1
#define QUIC_API_ENABLE_PREVIEW_FEATURES 1

#if defined(_DEBUG)
#define QUIC_EVENTS_STDOUT 1
#define QUIC_LOGS_STDOUT 1
#else
#define QUIC_EVENTS_STUB 1
#define QUIC_LOGS_STUB 1
#endif

#include "msquic/src/inc/msquic.h"

EXTERN_C_START

#pragma push_macro("_IRQL_requires_max_")
#if defined(KNSOFT_QUIC_BUILD) && defined(_WINDLL)
#undef _IRQL_requires_max_
#define _IRQL_requires_max_(x) __declspec(dllexport)
#elif defined(KNSOFT_QUIC_DLL)
#undef _IRQL_requires_max_
#define _IRQL_requires_max_(x) __declspec(dllimport)
#endif

_IRQL_requires_max_(DISPATCH_LEVEL)
void
QUIC_API
MsQuicSetContext(
    _In_ _Pre_defensive_ HQUIC Handle,
    _In_opt_ void* Context
    );

_IRQL_requires_max_(DISPATCH_LEVEL)
void*
QUIC_API
MsQuicGetContext(
    _In_ _Pre_defensive_ HQUIC Handle
    );

_IRQL_requires_max_(DISPATCH_LEVEL)
void
QUIC_API
MsQuicSetCallbackHandler(
    _In_ _Pre_defensive_ HQUIC Handle,
    _In_ void* Handler,
    _In_opt_ void* Context
    );

#include "msquic/src/core/api.h"

_IRQL_requires_max_(PASSIVE_LEVEL)
void
MsQuicLibraryLoad(
    void
    );

_IRQL_requires_max_(PASSIVE_LEVEL)
void
MsQuicLibraryUnload(
    void
    );

_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
MsQuicAddRef(
    void
    );

_IRQL_requires_max_(PASSIVE_LEVEL)
void
MsQuicRelease(
    void
    );

#pragma pop_macro("_IRQL_requires_max_")

static
FORCEINLINE
QUIC_STATUS
KNSoftQuicInitialize(
    void
    )
{
    MsQuicLibraryLoad();

    QUIC_STATUS Status = MsQuicAddRef();
    if (QUIC_FAILED(Status)) {
        MsQuicLibraryUnload();
    }

    return Status;
}

static
FORCEINLINE
void
KNSoftQuicUninitialize(
    void
    )
{
    MsQuicRelease();
    MsQuicLibraryUnload();
}

EXTERN_C_END
