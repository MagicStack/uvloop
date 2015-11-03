from libc.stdint cimport uint16_t, uint32_t, uint64_t


cdef extern from "sys/socket.h":
    struct addrinfo:
        int ai_flags
        int ai_family
        int ai_socktype
        int ai_protocol
        # ...


cdef extern from "../vendor/libuv/include/uv.h":

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

    ctypedef struct uv_getaddrinfo_t:
        void* data
        # ,,,

    ctypedef struct uv_getnameinfo_t:
        void* data
        # ,,,

    ctypedef enum uv_run_mode:
        UV_RUN_DEFAULT = 0,
        UV_RUN_ONCE,
        UV_RUN_NOWAIT

    const char* uv_strerror(int err)
    const char* uv_err_name(int err)

    ctypedef void (*uv_close_cb)(uv_handle_t* handle)
    ctypedef void (*uv_idle_cb)(uv_idle_t* handle)
    ctypedef void (*uv_signal_cb)(uv_signal_t* handle, int signum)
    ctypedef void (*uv_async_cb)(uv_async_t* handle)
    ctypedef void (*uv_timer_cb)(uv_timer_t* handle)

    # Generic handler functions
    void uv_close(uv_handle_t* handle, uv_close_cb close_cb)
    int uv_is_closing(const uv_handle_t* handle)

    # Loop functions
    int uv_loop_init(uv_loop_t* loop)
    int uv_loop_close(uv_loop_t* loop)

    uint64_t uv_now(const uv_loop_t*)

    int uv_run(uv_loop_t*, uv_run_mode mode)
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
