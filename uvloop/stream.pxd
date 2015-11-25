cdef class UVStream(UVHandle):
    cdef:
        uv.uv_shutdown_t _shutdown_req

    cdef _shutdown(self)

    cdef _listen(self, int backlog)
    cdef _accept(self, UVStream server)

    cdef _start_reading(self)
    cdef _stop_reading(self)

    cdef int _is_readable(self)
    cdef int _is_writable(self)

    cdef _write(self, object data, object callback)

    # The following methods have to be overridden:
    cdef _on_accept(self)
    cdef _on_listen(self)
    cdef _on_read(self, bytes buf)
    cdef _on_eof(self)
    cdef _on_write(self)
    cdef _on_shutdown(self)
