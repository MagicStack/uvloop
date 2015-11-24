cdef class UVHandle:
    cdef:
        uv.uv_handle_t *handle
        bint closed
        bint closing
        Loop loop

    cdef inline ensure_alive(self)
    cdef close(self)
