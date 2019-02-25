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

PyObject * Context_CopyCurrent(void) {
    PyErr_SetString(PyExc_NotImplementedError,
                    "\"contextvars\" support requires Python 3.7+");
    return NULL;
};

int Context_Enter(PyObject *ctx) {
    PyErr_SetString(PyExc_NotImplementedError,
                    "\"contextvars\" support requires Python 3.7+");
    return -1;
}

int Context_Exit(PyObject *ctx) {
    PyErr_SetString(PyExc_NotImplementedError,
                    "\"contextvars\" support requires Python 3.7+");
    return -1;
}

#elif PY_VERSION_HEX < 0x03070100

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


#if PY_VERSION_HEX < 0x03070000

void PyOS_BeforeFork(void)
{
    _PyImport_AcquireLock();
}

void PyOS_AfterFork_Parent(void)
{
    if (_PyImport_ReleaseLock() <= 0) {
        Py_FatalError("failed releasing import lock after fork");
    }
}


void PyOS_AfterFork_Child(void)
{
    PyOS_AfterFork();
}

#endif
