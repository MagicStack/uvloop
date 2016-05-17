cdef class UVStream(UVBaseTransport):
    cdef:
        uv.uv_shutdown_t _shutdown_req
        bint __shutting_down
        bint __reading
        bint __read_error_close
        bint _eof
        list _buffer
        size_t _buffer_size

    # All "inline" methods are final

    cdef inline _init(self, Loop loop, object protocol, Server server,
                      object waiter)

    cdef inline _exec_write(self)

    cdef inline _shutdown(self)
    cdef inline _accept(self, UVStream server)

    cdef inline _close_on_read_error(self)

    cdef inline __reading_started(self)
    cdef inline __reading_stopped(self)

    cdef inline _write(self, object data)
    cdef inline _try_write(self, object data)

    cdef _close(self)

    cdef inline _on_accept(self)
    cdef inline _on_read(self, bytes buf)
    cdef inline _on_eof(self)
    cdef inline _on_write(self)
    cdef inline _on_connect(self, object exc)
