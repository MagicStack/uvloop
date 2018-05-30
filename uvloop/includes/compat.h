#include <errno.h>
#include "Python.h"
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


#ifdef __linux__
#  define PLATFORM_IS_LINUX 1
#  include <sys/epoll.h>
#else
#  define PLATFORM_IS_LINUX 0
#  define EPOLL_CTL_DEL 2
struct epoll_event {};
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event) {};
#endif


#if PY_VERSION_HEX < 0x03070000
typedef struct {
    PyObject_HEAD
} PyContext;

PyContext * PyContext_CopyCurrent(void) {
    abort();
    return NULL;
};

int PyContext_Enter(PyContext *ctx) {
    abort();
    return -1;
}

int PyContext_Exit(PyContext *ctx) {
    abort();
    return -1;
}
#endif
