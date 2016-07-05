cdef class UVSignal(UVHandle):
    cdef:
        uv.uv_signal_t _handle_data
        Handle h
        bint running
        int signum

    cdef _init(self, Loop loop, Handle h, int signum)

    cdef stop(self)
    cdef start(self)

    @staticmethod
    cdef UVSignal new(Loop loop, Handle h, int signum)
