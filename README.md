# KNSoft.Quic

[![NuGet Downloads](https://img.shields.io/nuget/dt/KNSoft.Quic)](https://www.nuget.org/packages/KNSoft.Quic) [![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/KNSoft/KNSoft.Quic/Build_Publish.yml)](https://github.com/KNSoft/KNSoft.Quic/actions/workflows/Build_Publish.yml) [![GitHub License](https://img.shields.io/github/license/KNSoft/KNSoft.Quic)](https://github.com/KNSoft/KNSoft.Quic/blob/main/LICENSE)

KNSoft.Quic packages [MsQuic](https://github.com/microsoft/msquic):
- Provides `/MT` and `/MD` DLLs, regular and LTCG static libraries, and bundled PGO profiles for Windows
- Exposes function-table entries for direct calls
- Integrates with Visual Studio through NuGet

## Usage

Install [KNSoft.Quic](https://www.nuget.org/packages/KNSoft.Quic), then select `Configuration Properties > KNSoft.Quic > Integration Mode`.

| Mode | Artifact |
| --- | --- |
| DLL MT | `/MT` DLL |
| DLL MD | `/MD` DLL |
| Static | Static library |
| Static LTCG | LTCG static library |
| Static LTCG + Bundled PGO | LTCG library with bundled PGO |
| Manual | None; adds the library search path |
| None | None |

### Function table (standard MsQuic usage)

```C
#include <KNSoft.Quic.h>

const QUIC_API_TABLE* Api;
QUIC_STATUS Status = MsQuicOpenVersion(QUIC_API_VERSION_2, (const void**)&Api);
if (QUIC_SUCCEEDED(Status)) {
    MsQuicClose(Api);
}
```

### Direct calls (KNSoft.Quic exposes the function-table entries)

```C
QUIC_STATUS Status = KNSoftQuicInitialize();
if (QUIC_SUCCEEDED(Status)) {
    const QUIC_REGISTRATION_CONFIG Config = {
        "Application",
        QUIC_EXECUTION_PROFILE_LOW_LATENCY
    };
    HQUIC Registration;

    Status = MsQuicRegistrationOpen(&Config, &Registration);
    if (QUIC_SUCCEEDED(Status)) {
        MsQuicRegistrationClose(Registration);
    }
    KNSoftQuicUninitialize();
}
```

## Compatibility

Windows user mode with Schannel. x86, x64, ARM64, and ARM64EC. LTCG builds require the matching MSVC toolset generation.

## PGO

Profiles are trained with SecNetPerf using local and emulated-network scenarios defined in [Training.json](https://github.com/KNSoft/KNSoft.Quic/blob/main/PGO/Training.json). Results and validation data are recorded in each platform's `manifest.json` under [PGO](https://github.com/KNSoft/KNSoft.Quic/tree/main/PGO).

```PowerShell
.\PGO\Build-SecNetPerf.ps1
.\PGO\Train.ps1
```

## License

KNSoft.Quic is licensed under the [MIT License](https://github.com/KNSoft/KNSoft.Quic/blob/main/LICENSE). It incorporates [MsQuic](https://github.com/microsoft/msquic), also licensed under the MIT License.
