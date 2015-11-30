cdef class UVSignal(UVHandle):
    cdef:
        object callback
        bint running
        int signum

    cdef stop(self)
    cdef start(self)
