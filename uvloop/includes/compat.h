#include <errno.h>
#include <stddef.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "Python.h"
#include "uv.h"


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
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event) {
    return 0;
};
#endif


PyObject *
MakeUnixSockPyAddr(struct sockaddr_un *addr)
{
    if (addr->sun_family != AF_UNIX) {
        PyErr_SetString(
            PyExc_ValueError, "a UNIX socket addr was expected");
        return NULL;
    }

#ifdef __linux__
    int addrlen = sizeof (struct sockaddr_un);
    size_t linuxaddrlen = addrlen - offsetof(struct sockaddr_un, sun_path);
    if (linuxaddrlen > 0 && addr->sun_path[0] == 0) {
        return PyBytes_FromStringAndSize(addr->sun_path, linuxaddrlen);
    }
    else
#endif /* linux */
    {
        /* regular NULL-terminated string */
        return PyUnicode_DecodeFSDefault(addr->sun_path);
    }
}


#if PY_VERSION_HEX < 0x03070100

PyObject * Context_CopyCurrent(void) {
    return (PyObject *)PyContext_CopyCurrent();
};

int Context_Enter(PyObject *ctx) {
    return PyContext_Enter((PyContext *)ctx);
}

int Context_Exit(PyObject *ctx) {
    return PyContext_Exit((PyContext *)ctx);
}

#else

PyObject * Context_CopyCurrent(void) {
    return PyContext_CopyCurrent();
};

int Context_Enter(PyObject *ctx) {
    return PyContext_Enter(ctx);
}

int Context_Exit(PyObject *ctx) {
    return PyContext_Exit(ctx);
}

#endif
