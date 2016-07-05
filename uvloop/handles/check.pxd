cdef class UVCheck(UVHandle):
    cdef:
        uv.uv_check_t _handle_data
        Handle h
        bint running

    # All "inline" methods are final

    cdef _init(self, Loop loop, Handle h)

    cdef inline stop(self)
    cdef inline start(self)

    @staticmethod
    cdef UVCheck new(Loop loop, Handle h)
