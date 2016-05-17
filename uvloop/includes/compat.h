#include <errno.h>
#include "uv.h"


// uv_poll_event.UV_DISCONNECT is available since libuv v1.9.0
#if UV_VERSION_HEX < 0x10900
#define UV_DISCONNECT 0
#endif

#ifndef EWOULDBLOCK
#define EWOULDBLOCK EAGAIN
#endif

#ifdef __APPLE__
#define PLATFORM_IS_APPLE 1
#else
#define PLATFORM_IS_APPLE 0
#endif
