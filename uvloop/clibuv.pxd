from libc.stdint cimport uint16_t, uint32_t, uint64_t


cdef extern from "../vendor/libuv/include/uv.h":

    ctypedef struct uv_loop_t:
        void* data

        # Loop reference counting.
        unsigned int active_handles
        void* handle_queue[2]
        void* active_reqs[2]

        # Internal flag to signal loop stop.
        unsigned int stop_flag

    int uv_loop_init(uv_loop_t* loop)
    int uv_loop_close(uv_loop_t* loop)

    uint64_t uv_now(const uv_loop_t*)
