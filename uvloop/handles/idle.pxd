cdef class UVIdle(UVHandle):
    cdef:
        Handle h
        bint running

    cdef _init(self, Loop loop, Handle h)

    cdef stop(self)
    cdef start(self)

    @staticmethod
    cdef UVIdle new(Loop loop, Handle h)
