cdef class UVStream(UVBaseTransport):
    cdef:
        uv.uv_shutdown_t _shutdown_req
        bint __shutting_down
        bint __reading
        bint __read_error_close
        bint _eof

    cdef _init(self, Loop loop, object protocol, Server server, object waiter)

    cdef _shutdown(self)

    cdef _listen(self, int backlog)
    cdef _accept(self, UVStream server)

    cdef inline _close_on_read_error(self)

    cdef inline __reading_started(self)
    cdef inline __reading_stopped(self)

    cdef _write(self, object data)

    cdef _close(self)

    cdef _on_accept(self)
    cdef _on_listen(self)
    cdef _on_read(self, bytes buf)
    cdef _on_eof(self)
    cdef _on_write(self)
    cdef _on_shutdown(self)
    cdef _on_connect(self, object exc)
