cdef class UVTimer(UVHandle):
    cdef:
        object callback
        bint running
        uint64_t timeout

    cdef stop(self)
    cdef start(self)
