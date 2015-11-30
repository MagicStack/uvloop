cdef class UVIdle(UVHandle):
    cdef:
        method_t* callback
        object ctx
        bint running

    cdef _init(self, method_t* callback, object ctx)

    cdef stop(self)
    cdef start(self)

    @staticmethod
    cdef UVIdle new(Loop loop, method_t* callback, object ctx)
