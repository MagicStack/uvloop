cdef class UVTimer(UVHandle):
    cdef:
        uv.uv_timer_t _handle_data
        method_t callback
        object ctx
        bint running
        uint64_t timeout
        uv.uv_timer_t _handle_impl

    cdef _init(self, Loop loop, method_t callback, object ctx,
               uint64_t timeout)

    cdef stop(self)
    cdef start(self)

    @staticmethod
    cdef UVTimer new(Loop loop, method_t callback, object ctx,
                     uint64_t timeout)
