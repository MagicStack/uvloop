from libc.stdint cimport uint16_t, uint32_t, uint64_t


cdef extern from "../vendor/libuv/include/uv.h":
    cdef int UV_ECANCELED
    cdef int UV_EOF


    cdef int SOL_SOCKET
    cdef int SO_REUSEADDR
    cdef int SO_REUSEPORT
    cdef int AF_INET
    cdef int AF_INET6
    cdef int AF_UNSPEC
    cdef int AI_PASSIVE
    cdef int INET6_ADDRSTRLEN
    cdef int IPV6_V6ONLY
    cdef int IPPROTO_IPV6

    cdef int SIGINT
    cdef int SIGHUP

    ctypedef struct uv_buf_t:
      char* base
      size_t len

    ctypedef struct uv_loop_t:
        void* data
        # ,,,

    ctypedef struct uv_handle_t:
        void* data
        # ...

    ctypedef struct uv_idle_t:
        void* data
        # ,,,

    ctypedef struct uv_signal_t:
        void* data
        # ,,,

    ctypedef struct uv_async_t:
        void* data
        # ,,,

    ctypedef struct uv_timer_t:
        void* data
        # ,,,

    ctypedef struct uv_stream_t:
        void* data
        # ,,,

    ctypedef struct uv_tcp_t:
        void* data
        # ,,,

    ctypedef struct uv_getaddrinfo_t:
        void* data
        # ,,,

    ctypedef struct uv_getnameinfo_t:
        void* data
        # ,,,

    ctypedef struct uv_write_t:
        void* data
        # ...

    ctypedef enum uv_run_mode:
        UV_RUN_DEFAULT = 0,
        UV_RUN_ONCE,
        UV_RUN_NOWAIT

    const char* uv_strerror(int err)
    const char* uv_err_name(int err)

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
                                       addrinfo* res) with gil

    # Buffers

    uv_buf_t uv_buf_init(char* base, unsigned int len)

    # Generic handler functions
    void uv_close(uv_handle_t* handle, uv_close_cb close_cb)
    int uv_is_closing(const uv_handle_t* handle)

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
    struct sockaddr:
        unsigned short sa_family
        char           sa_data[14]

    struct addrinfo:
        int            ai_flags
        int            ai_family
        int            ai_socktype
        int            ai_protocol
        size_t         ai_addrlen
        sockaddr*      ai_addr
        char*          ai_canonname
        addrinfo*      ai_next

    struct sockaddr_in:
        short          sin_family
        unsigned short sin_port
        # ...

    struct sockaddr_in6:
        short          sin6_family
        unsigned short sin6_port;
        unsigned long  sin6_flowinfo
        # ...
        unsigned long  sin6_scope_id

    int uv_getaddrinfo(uv_loop_t* loop,
                       uv_getaddrinfo_t* req,
                       uv_getaddrinfo_cb getaddrinfo_cb,
                       const char* node,
                       const char* service,
                       const addrinfo* hints)

    void uv_freeaddrinfo(addrinfo* ai)

    int ntohl(int)
    int ntohs(int)

    int uv_ip4_name(const sockaddr_in* src, char* dst, size_t size)
    int uv_ip6_name(const sockaddr_in6* src, char* dst, size_t size)

    # Streams

    int uv_listen(uv_stream_t* stream, int backlog, uv_connection_cb cb)
    int uv_accept(uv_stream_t* server, uv_stream_t* client)
    int uv_read_start(uv_stream_t* stream,
                      uv_alloc_cb alloc_cb,
                      uv_read_cb read_cb)
    int uv_read_stop(uv_stream_t*)
    int uv_write(uv_write_t* req, uv_stream_t* handle,
                 uv_buf_t bufs[], unsigned int nbufs, uv_write_cb cb)

    # TCP

    ctypedef uv_os_sock_t

    int uv_tcp_init(uv_loop_t*, uv_tcp_t* handle)
    int uv_tcp_nodelay(uv_tcp_t* handle, int enable)
    int uv_tcp_open(uv_tcp_t* handle, uv_os_sock_t sock)
    int uv_tcp_bind(uv_tcp_t* handle, sockaddr* addr, unsigned int flags)
