cdef class UVTimer(UVHandle):
    cdef:
        object callback
        int running
        uint64_t timeout

    cdef stop(self)
    cdef start(self)
