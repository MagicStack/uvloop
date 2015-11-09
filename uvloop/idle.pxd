cdef class UVIdle(UVHandle):
    cdef:
        object callback
        bint running

    cdef stop(self)
    cdef start(self)
