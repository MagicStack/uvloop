#include "uv.h"


// uv_poll_event.UV_DISCONNECT is available since libuv v1.9.0
#if UV_VERSION_HEX < 0x10900
#define UV_DISCONNECT 0
#endif
