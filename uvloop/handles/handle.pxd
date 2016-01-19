cdef class UVHandle:
    cdef:
        uv.uv_handle_t *_handle
        bint _closed
        Loop _loop

    cdef inline _set_loop(self, Loop loop)
    cdef inline bint _is_alive(self)
    cdef inline _ensure_alive(self)

    cdef _error(self, exc, throw)
    cdef _fatal_error(self, exc, throw)

    cdef _close(self)
