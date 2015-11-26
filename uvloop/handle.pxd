cdef class UVHandle:
    cdef:
        uv.uv_handle_t *_handle
        bint _closed
        Loop _loop

    cdef inline bint _is_alive(self)
    cdef inline _ensure_alive(self)

    cdef _close(self)
