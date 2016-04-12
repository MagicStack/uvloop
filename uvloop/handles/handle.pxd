cdef class UVHandle:
    cdef:
        uv.uv_handle_t *_handle
        bint _closed
        bint _inited
        Loop _loop

    cdef inline _start_init(self, Loop loop)
    cdef inline _abort_init(self)
    cdef inline _finish_init(self)


    cdef inline bint _is_alive(self)
    cdef inline _ensure_alive(self)

    cdef _error(self, exc, throw)
    cdef _fatal_error(self, exc, throw, reason=?)

    cdef _free(self)
    cdef _close(self)
