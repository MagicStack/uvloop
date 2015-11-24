cdef class UVHandle:
    cdef:
        uv.uv_handle_t *_handle
        bint _closed
        bint _closing
        Loop _loop

    cdef inline _ensure_alive(self)
    cdef close(self)
