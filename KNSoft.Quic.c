#define WIN32_LEAN_AND_MEAN 1
#define SECURITY_WIN32 1

#define QUIC_BUILD_STATIC 1

#if defined(_DEBUG)
#define QUIC_EVENTS_STDOUT 1
#define QUIC_LOGS_STDOUT 1
#pragma warning(push)
#pragma warning(disable:4996) /* Upstream stdout helper uses strdup. */
#include "msquic/src/generated/stdout/quic_trace.c"
#pragma warning(pop)
#else
#define QUIC_EVENTS_STUB 1
#define QUIC_LOGS_STUB 1
#endif

/* Patch precomp.h */
#include "precomp.h"
#pragma include_alias("precomp.h", "../../../precomp.h")

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ncrypt.lib")
#pragma comment(lib, "ntdll.lib")
#pragma comment(lib, "onecore.lib")
#pragma comment(lib, "schannel.lib")
#pragma comment(lib, "secur32.lib")
#pragma comment(lib, "wbemuuid.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "ws2_32.lib")
#if defined(_M_ARM64EC)
#pragma comment(lib, "softintrin.lib")
#endif

/* MsQuic core. Keep this list synchronized with src/core/CMakeLists.txt. */
#include "msquic/src/core/ack_tracker.c"
#include "msquic/src/core/api.c"
#include "msquic/src/core/binding.c"
#include "msquic/src/core/configuration.c"
#include "msquic/src/core/congestion_control.c"
#include "msquic/src/core/connection.c"
#include "msquic/src/core/connection_pool.c"
#include "msquic/src/core/crypto.c"
#include "msquic/src/core/crypto_tls.c"
#include "msquic/src/core/cubic.c"
#include "msquic/src/core/bbr.c"
#include "msquic/src/core/datagram.c"
#include "msquic/src/core/frame.c"
#include "msquic/src/core/partition.c"
#include "msquic/src/core/library.c"
#include "msquic/src/core/listener.c"
#include "msquic/src/core/lookup.c"
#include "msquic/src/core/loss_detection.c"
#include "msquic/src/core/mtu_discovery.c"
#include "msquic/src/core/operation.c"
#include "msquic/src/core/packet.c"
#include "msquic/src/core/packet_builder.c"
#include "msquic/src/core/packet_space.c"
#include "msquic/src/core/path.c"
#include "msquic/src/core/range.c"
#include "msquic/src/core/recv_buffer.c"
#include "msquic/src/core/registration.c"
#include "msquic/src/core/send.c"
#include "msquic/src/core/send_buffer.c"
#include "msquic/src/core/sent_packet_metadata.c"
#include "msquic/src/core/settings.c"
#include "msquic/src/core/stream.c"
#include "msquic/src/core/stream_recv.c"
#include "msquic/src/core/stream_send.c"
#include "msquic/src/core/stream_set.c"
#include "msquic/src/core/timer_wheel.c"
#include "msquic/src/core/worker.c"
#include "msquic/src/core/version_neg.c"
#include "msquic/src/core/sliding_window_extremum.c"

/* Platform-independent platform layer. */
#include "msquic/src/platform/crypt.c"
#include "msquic/src/platform/hashtable.c"
#include "msquic/src/platform/pcp.c"
#include "msquic/src/platform/platform_worker.c"
#include "msquic/src/platform/toeplitz.c"

/* Windows user-mode platform layer. */
#include "msquic/src/platform/platform_winuser.c"
#include "msquic/src/platform/storage_winuser.c"
#include "msquic/src/platform/datapath_win.c"
#include "msquic/src/platform/datapath_winuser.c"
#include "msquic/src/platform/datapath_xplat.c"

/* Keep the optional raw/XDP datapath disabled. */
/* Define the raw datapath's private send-data layout under a unique name. */
#define CXPLAT_SEND_DATA CXPLAT_SEND_DATA_RAW
#include "msquic/src/platform/datapath_raw.h"
#undef CXPLAT_SEND_DATA
#include "msquic/src/platform/datapath_raw_dummy.c"

/* Schannel is the only TLS provider in this wrapper. */
#include "msquic/src/platform/cert_capi.c"
#include "msquic/src/platform/crypt_bcrypt.c"
#define TlsHandshake_ClientHello TlsHandshake_ClientHello_Schannel
#include "msquic/src/platform/tls_schannel.c"
#undef TlsHandshake_ClientHello
