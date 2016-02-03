from libc.stdint cimport uint16_t, uint32_t, uint64_t

from . cimport system


cdef extern from "../vendor/libuv/include/uv.h":
    cdef int UV_EINVAL
    cdef int UV_EBUSY
    cdef int UV_ECANCELED
    cdef int UV_EOF
    cdef int UV_ECONNRESET


    cdef int SOL_SOCKET
    cdef int SO_ERROR
    cdef int SO_REUSEADDR
    cdef int SO_REUSEPORT
    cdef int AF_INET
    cdef int AF_INET6
    cdef int AF_UNSPEC
    cdef int AI_PASSIVE
    cdef int INET6_ADDRSTRLEN
    cdef int IPV6_V6ONLY
    cdef int IPPROTO_IPV6
    cdef int SOCK_STREAM

    cdef int SIGINT
    cdef int SIGHUP


    cdef int UV_EAI_ADDRFAMILY
    cdef int UV_EAI_AGAIN
    cdef int UV_EAI_BADFLAGS
    cdef int UV_EAI_BADHINTS
    cdef int UV_EAI_CANCELED
    cdef int UV_EAI_FAIL
    cdef int UV_EAI_FAMILY
    cdef int UV_EAI_MEMORY
    cdef int UV_EAI_NODATA
    cdef int UV_EAI_NONAME
    cdef int UV_EAI_OVERFLOW
    cdef int UV_EAI_PROTOCOL
    cdef int UV_EAI_SERVICE
    cdef int UV_EAI_SOCKTYPE


    ctypedef struct uv_os_sock_t
    ctypedef struct uv_os_fd_t    # not really a struct; tricking Cython here.

    ctypedef struct uv_buf_t:
      char* base
      size_t len

    ctypedef struct uv_loop_t:
        void* data
        # ...

    ctypedef struct uv_handle_t:
        void* data
        uv_loop_t* loop
        # ...

    ctypedef struct uv_idle_t:
        void* data
        uv_loop_t* loop
        # ...

    ctypedef struct uv_signal_t:
        void* data
        uv_loop_t* loop
        # ...

    ctypedef struct uv_async_t:
        void* data
        uv_loop_t* loop
        # ...

    ctypedef struct uv_timer_t:
        void* data
        uv_loop_t* loop
        # ...

    ctypedef struct uv_stream_t:
        void* data
        size_t write_queue_size
        uv_loop_t* loop
        # ...

    ctypedef struct uv_tcp_t:
        void* data
        uv_loop_t* loop
        # ...

    ctypedef struct uv_poll_t:
        void* data
        uv_loop_t* loop
        # ...

    ctypedef struct uv_req_t:
        # Only cancellation of uv_fs_t, uv_getaddrinfo_t,
        # uv_getnameinfo_t and uv_work_t requests is
        # currently supported.
        void* data
        uv_req_type type
        # ...

    ctypedef struct uv_getaddrinfo_t:
        void* data
        # ...

    ctypedef struct uv_getnameinfo_t:
        void* data
        # ...

    ctypedef struct uv_write_t:
        void* data
        # ...

    ctypedef struct uv_shutdown_t:
        void* data
        # ...

    ctypedef enum uv_req_type:
        UV_UNKNOWN_REQ = 0,
        UV_REQ,
        UV_CONNECT,
        UV_WRITE,
        UV_SHUTDOWN,
        UV_UDP_SEND,
        UV_FS,
        UV_WORK,
        UV_GETADDRINFO,
        UV_GETNAMEINFO,
        UV_REQ_TYPE_PRIVATE,
        UV_REQ_TYPE_MAX

    ctypedef enum uv_run_mode:
        UV_RUN_DEFAULT = 0,
        UV_RUN_ONCE,
        UV_RUN_NOWAIT

    ctypedef enum uv_poll_event:
        UV_READABLE = 1,
        UV_WRITABLE = 2

    const char* uv_strerror(int err)
    const char* uv_err_name(int err)

    # no "with gil" for uv_walk_cb, as uv_walk doesn't release GIL
    ctypedef void (*uv_walk_cb)(uv_handle_t* handle, void* arg)

    ctypedef void (*uv_close_cb)(uv_handle_t* handle) with gil
    ctypedef void (*uv_idle_cb)(uv_idle_t* handle) with gil
    ctypedef void (*uv_signal_cb)(uv_signal_t* handle, int signum) with gil
    ctypedef void (*uv_async_cb)(uv_async_t* handle) with gil
    ctypedef void (*uv_timer_cb)(uv_timer_t* handle) with gil
    ctypedef void (*uv_connection_cb)(uv_stream_t* server, int status) with gil
    ctypedef void (*uv_alloc_cb)(uv_handle_t* handle,
                                 size_t suggested_size,
                                 uv_buf_t* buf) with gil
    ctypedef void (*uv_read_cb)(uv_stream_t* stream,
                                ssize_t nread,
                                const uv_buf_t* buf) with gil
    ctypedef void (*uv_write_cb)(uv_write_t* req, int status) with gil
    ctypedef void (*uv_getaddrinfo_cb)(uv_getaddrinfo_t* req,
                                       int status,
                                       system.addrinfo* res) with gil
    ctypedef void (*uv_shutdown_cb)(uv_shutdown_t* req, int status) with gil
    ctypedef void (*uv_poll_cb)(uv_poll_t* handle,
                                int status, int events) with gil

    # Buffers

    uv_buf_t uv_buf_init(char* base, unsigned int len)

    # Generic request functions
    int uv_cancel(uv_req_t* req)

    # Generic handler functions
    void uv_close(uv_handle_t* handle, uv_close_cb close_cb)
    int uv_is_closing(const uv_handle_t* handle)
    int uv_fileno(const uv_handle_t* handle, uv_os_fd_t* fd)
    void uv_walk(uv_loop_t* loop, uv_walk_cb walk_cb, void* arg)

    # Loop functions
    int uv_loop_init(uv_loop_t* loop)
    int uv_loop_close(uv_loop_t* loop)
    int uv_loop_alive(uv_loop_t* loop)

    uint64_t uv_now(const uv_loop_t*)

    int uv_run(uv_loop_t*, uv_run_mode mode) nogil
    void uv_stop(uv_loop_t*)

    # Idle handler
    int uv_idle_init(uv_loop_t*, uv_idle_t* idle)
    int uv_idle_start(uv_idle_t* idle, uv_idle_cb cb)
    int uv_idle_stop(uv_idle_t* idle)

    # Signal handler
    int uv_signal_init(uv_loop_t* loop, uv_signal_t* handle)
    int uv_signal_start(uv_signal_t* handle,
                        uv_signal_cb signal_cb,
                        int signum)
    int uv_signal_stop(uv_signal_t* handle)

    # Async handler
    int uv_async_init(uv_loop_t*,
                      uv_async_t* async,
                      uv_async_cb async_cb)
    int uv_async_send(uv_async_t* async)

    # Timer handler
    int uv_timer_init(uv_loop_t*, uv_timer_t* handle)
    int uv_timer_start(uv_timer_t* handle,
                       uv_timer_cb cb,
                       uint64_t timeout,
                       uint64_t repeat)
    int uv_timer_stop(uv_timer_t* handle)

    # DNS
    int uv_getaddrinfo(uv_loop_t* loop,
                       uv_getaddrinfo_t* req,
                       uv_getaddrinfo_cb getaddrinfo_cb,
                       const char* node,
                       const char* service,
                       const system.addrinfo* hints)

    void uv_freeaddrinfo(system.addrinfo* ai)

    int ntohl(int)
    int ntohs(int)

    int uv_ip4_name(const system.sockaddr_in* src, char* dst, size_t size)
    int uv_ip6_name(const system.sockaddr_in6* src, char* dst, size_t size)

    # Streams

    int uv_listen(uv_stream_t* stream, int backlog, uv_connection_cb cb)
    int uv_accept(uv_stream_t* server, uv_stream_t* client)
    int uv_read_start(uv_stream_t* stream,
                      uv_alloc_cb alloc_cb,
                      uv_read_cb read_cb)
    int uv_read_stop(uv_stream_t*)
    int uv_write(uv_write_t* req, uv_stream_t* handle,
                 uv_buf_t bufs[], unsigned int nbufs, uv_write_cb cb)

    int uv_shutdown(uv_shutdown_t* req, uv_stream_t* handle, uv_shutdown_cb cb)

    int uv_is_readable(const uv_stream_t* handle)
    int uv_is_writable(const uv_stream_t* handle)

    # TCP

    int uv_tcp_init(uv_loop_t*, uv_tcp_t* handle)
    int uv_tcp_nodelay(uv_tcp_t* handle, int enable)
    int uv_tcp_keepalive(uv_tcp_t* handle, int enable, unsigned int delay)
    int uv_tcp_open(uv_tcp_t* handle, uv_os_sock_t sock)
    int uv_tcp_bind(uv_tcp_t* handle, system.sockaddr* addr, unsigned int flags)

    int uv_tcp_getsockname(const uv_tcp_t* handle, system.sockaddr* name,
                           int* namelen)

    # Polling

    int uv_poll_init(uv_loop_t* loop, uv_poll_t* handle, int fd)
    int uv_poll_init_socket(uv_loop_t* loop, uv_poll_t* handle,
                            uv_os_sock_t socket)
    int uv_poll_start(uv_poll_t* handle, int events, uv_poll_cb cb)
    int uv_poll_stop(uv_poll_t* poll)

    # Misc

    ctypedef struct uv_timeval_t:
        long tv_sec
        long tv_usec

    ctypedef struct uv_rusage_t:
        uv_timeval_t ru_utime   # user CPU time used
        uv_timeval_t ru_stime   # system CPU time used
        uint64_t ru_maxrss      # maximum resident set size
        uint64_t ru_ixrss       # integral shared memory size
        uint64_t ru_idrss       # integral unshared data size
        uint64_t ru_isrss       # integral unshared stack size
        uint64_t ru_minflt      # page reclaims (soft page faults)
        uint64_t ru_majflt      # page faults (hard page faults)
        uint64_t ru_nswap       # swaps
        uint64_t ru_inblock     # block input operations
        uint64_t ru_oublock     # block output operations
        uint64_t ru_msgsnd      # IPC messages sent
        uint64_t ru_msgrcv      # IPC messages received
        uint64_t ru_nsignals    # signals received
        uint64_t ru_nvcsw       # voluntary context switches
        uint64_t ru_nivcsw      # involuntary context switches

    int uv_getrusage(uv_rusage_t* rusage)

    # Memory Allocation

    ctypedef void* (*uv_malloc_func)(size_t size)
    ctypedef void* (*uv_realloc_func)(void* ptr, size_t size)
    ctypedef void* (*uv_calloc_func)(size_t count, size_t size)
    ctypedef void (*uv_free_func)(void* ptr)

    int uv_replace_allocator(uv_malloc_func malloc_func,
                             uv_realloc_func realloc_func,
                             uv_calloc_func calloc_func,
                             uv_free_func free_func)
