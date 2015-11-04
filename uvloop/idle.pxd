cdef class UVIdle(UVHandle):
    cdef:
        object callback
        int running

    cdef stop(self)
    cdef start(self)
