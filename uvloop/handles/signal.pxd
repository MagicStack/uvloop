cdef class UVSignal(UVHandle):
    cdef:
        method_t* callback
        object ctx
        bint running
        int signum

    cdef _init(self, Loop loop, method_t* callback, object ctx, int signum)

    cdef stop(self)
    cdef start(self)

    @staticmethod
    cdef UVSignal new(Loop loop, method_t* callback, object ctx,
                      int signum)
