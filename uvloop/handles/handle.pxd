cdef class UVHandle:
    cdef:
        uv.uv_handle_t *_handle
        bint _closed
        bint _inited
        Loop _loop

    # All "inline" methods are final

    cdef inline _start_init(self, Loop loop)
    cdef inline _abort_init(self)
    cdef inline _finish_init(self)

    cdef inline bint _is_alive(self)
    cdef inline _ensure_alive(self)

    cdef _error(self, exc, throw)
    cdef _fatal_error(self, exc, throw, reason=?)

    cdef _free(self)
    cdef _close(self)


cdef class UVSocketHandle(UVHandle):
    cdef:
        # Points to a Python file-object that should be closed
        # when the transport is closing.  Used by pipes.  This
        # should probably be refactored somehow.
        object _fileobj
        object __cached_socket

    # All "inline" methods are final

    cdef inline _fileno(self)

    cdef _new_socket(self)
    cdef inline _get_socket(self)
    cdef inline _attach_fileobj(self, object file)
