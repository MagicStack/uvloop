cdef class UVTimer(UVHandle):
    cdef:
        method_t* callback
        object ctx
        bint running
        uint64_t timeout

    cdef _init(self, Loop loop, method_t* callback, object ctx,
               uint64_t timeout)

    cdef stop(self)
    cdef start(self)

    @staticmethod
    cdef UVTimer new(Loop loop, method_t* callback, object ctx,
                     uint64_t timeout)
