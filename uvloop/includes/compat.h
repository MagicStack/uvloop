#include <errno.h>
#include <stddef.h>

#ifdef _WIN32
#define PLATFORM_IS_WINDOWS 1
#else
#define PLATFORM_IS_WINDOWS 0
#include <sys/socket.h>
#include <sys/un.h>
#endif

#include "Python.h"
#include "uv.h"

#include <signal.h>


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

struct epoll_event {
    uint32_t events;
    void *ptr;
};
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)
{
    return 0;
};
#endif

#ifdef _WIN32
#pragma warning(disable : 4311 4312)

#ifndef SIGCHLD
#define SIGCHLD 17
#endif

#ifndef SO_REUSEPORT
#define SO_REUSEPORT 15
#endif

#include <stdio.h>
#include <windows.h>

struct sockaddr_un
{
    unsigned short sun_family;
    char           sun_path[108];
};

int socketpair(int domain, int type, int protocol, int fds[2])
{
    uv_os_sock_t socket_vector[2];
    int ret = uv_socketpair(type, protocol, socket_vector, UV_NONBLOCK_PIPE, UV_NONBLOCK_PIPE);
    fds[0] = (int)socket_vector[0];
    fds[1] = (int)socket_vector[1];
    return ret;
}

void CloseIOCP(void* handle) {
  uv_loop_t* loop = (uv_loop_t*)handle;
  assert(loop != NULL);
  //printf("loop=0x%p, active_count=%d\n",loop, loop->active_handles);
  if (loop->data) {
      uv_loop_t* data = (uv_loop_t*)loop;
      //printf("loop->data=0x%p, active_count=%d\n", data, data->active_handles);
  }
  if (loop->iocp != INVALID_HANDLE_VALUE)
  {
      //printf("loop=0x%p, active_count=%d\n",loop, loop->active_handles);
      //uv_print_all_handles(loop, stderr);
#if 0
      HANDLE iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);
      DWORD bytes;
      ULONG_PTR key;
      LPOVERLAPPED overlapped;
      GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped, 0);
#endif
      //CloseHandle(iocp);
      PostQueuedCompletionStatus(loop->iocp, 0, 0, NULL); //wakeup iocp as thread waiting
//      CloseHandle(loop->iocp);
//      loop->iocp = INVALID_HANDLE_VALUE;
  }
}

void DbgBreak() {
    if(IsDebuggerPresent())
    {
       DebugBreak();
    }
}
#else
#define PLATFORM_IS_WINDOWS 0
void CloseIOCP(void* handle) {}

void DebugBreak(void)
{
    raise(SIGTRAP);
}
#endif

void PrintAllHandle(void* handle) {
    uv_loop_t* loop = (uv_loop_t*)handle;
    uv_print_all_handles(loop, stderr);
    printf("loop=0x%p, active_count=%d\n",loop, loop->active_handles);
}

int create_tcp_socket(void) {
  return (int)socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
}

void stdio_container_init(void *pipe, int fd)
{
    uv_pipe_t* handle = (uv_pipe_t*)pipe;
    memset(handle, 0, sizeof(uv_pipe_t));
}

void process_init(void *process)
{
   memset(process, 0, sizeof(uv_process_t));
}

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
