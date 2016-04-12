cdef class UVSignal(UVHandle):
    cdef:
        Handle h
        bint running
        int signum

    cdef _init(self, Loop loop, Handle h, int signum)

    cdef stop(self)
    cdef start(self)

    @staticmethod
    cdef UVSignal new(Loop loop, Handle h, int signum)
