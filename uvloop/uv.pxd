from libc.stdint cimport uint16_t, uint32_t, uint64_t


cdef extern from "../vendor/libuv/include/uv.h":

    ctypedef struct uv_loop_t:
        void* data
        # ,,,

    ctypedef struct uv_idle_t:
        void* data
        # ,,,

    ctypedef struct uv_signal_t:
        void* data
        # ,,,

    ctypedef struct uv_async_t:
        void* data
        # ,,,

    ctypedef enum uv_run_mode:
        UV_RUN_DEFAULT = 0,
        UV_RUN_ONCE,
        UV_RUN_NOWAIT

    ctypedef void (*uv_idle_cb)(uv_idle_t* handle)
    ctypedef void (*uv_signal_cb)(uv_signal_t* handle, int signum)
    ctypedef void (*uv_async_cb)(uv_async_t* handle)

    int uv_loop_init(uv_loop_t* loop)
    int uv_loop_close(uv_loop_t* loop)

    uint64_t uv_now(const uv_loop_t*)

    int uv_run(uv_loop_t*, uv_run_mode mode)
    void uv_stop(uv_loop_t*)

    int uv_idle_init(uv_loop_t*, uv_idle_t* idle)
    int uv_idle_start(uv_idle_t* idle, uv_idle_cb cb)
    int uv_idle_stop(uv_idle_t* idle)

    int uv_signal_init(uv_loop_t* loop, uv_signal_t* handle)
    int uv_signal_start(uv_signal_t* handle,
                        uv_signal_cb signal_cb,
                        int signum)
    int uv_signal_stop(uv_signal_t* handle)

    int uv_async_init(uv_loop_t*,
                      uv_async_t* async,
                      uv_async_cb async_cb)

    int uv_async_send(uv_async_t* async)
