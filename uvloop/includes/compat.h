#include <errno.h>
#include <stddef.h>
#include <signal.h>
#ifndef _WIN32
#include <sys/socket.h>
#include <sys/un.h>
#include <arpa/inet.h>
#include <unistd.h>
#else
#include <io.h>
#include <winsock2.h>
#endif

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
/* error C2016: C requires that a struct or union have at least one member on Windows
with default compilation flags. Therefore put dummy field for now. */
struct epoll_event {int dummyfield;};
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event) {
    return 0;
};
#endif


#ifdef _WIN32
int SIGCHLD = 0;
int SO_REUSEPORT = 0;

struct sockaddr_un {unsigned short sun_family; char* sun_path;};

int socketpair(int domain, int type, int protocol, int socket_vector[2]) {
    return 0;
}

/* redefine write as counterpart of unistd.h/write */
int write(int fd, const void *buf, unsigned int count) {
    WSABUF wsa;
    unsigned long dbytes;
    wsa.buf = (char*)buf;
    wsa.len = (unsigned long)count;
    errno = WSASend(fd, &wsa, 1, &dbytes, 0, NULL, NULL);
    if (errno == SOCKET_ERROR) {
      errno = WSAGetLastError();
      if (errno == 10035)
        errno = EAGAIN;
      return -1;
    }
    else
      return dbytes;
}
#endif

PyObject *
MakeUnixSockPyAddr(struct sockaddr_un *addr)
{
#ifdef _WIN32
	return NULL;
#else
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
#endif /* _WIN32 */
}

#ifdef _WIN32
#define PLATFORM_IS_WINDOWS 1
int getuid() {
	return 0;
}
#else
#define PLATFORM_IS_WINDOWS 0
#endif


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

/* inlined from cpython/Modules/signalmodule.c
 * https://github.com/python/cpython/blob/v3.13.0a6/Modules/signalmodule.c#L1931-L1951
 * private _Py_RestoreSignals has been moved to CPython internals in Python 3.13
 * https://github.com/python/cpython/pull/106400 */

void
_Py_RestoreSignals(void)
{
#ifdef SIGPIPE
    PyOS_setsig(SIGPIPE, SIG_DFL);
#endif
#ifdef SIGXFZ
    PyOS_setsig(SIGXFZ, SIG_DFL);
#endif
#ifdef SIGXFSZ
    PyOS_setsig(SIGXFSZ, SIG_DFL);
#endif
}

#ifdef _WIN32
void PyOS_BeforeFork() {
    return;
}	
void PyOS_AfterFork_Parent() {
    return;
}
void PyOS_AfterFork_Child() {
    return;
}
#endif
