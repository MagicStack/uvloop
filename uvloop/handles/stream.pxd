cdef class UVStream(UVHandle):
    cdef:
        uv.uv_shutdown_t _shutdown_req
        bint __shutting_down
        bint __reading
        object __cached_socket

        # Points to a Python file-object that should be closed
        # when the transport is closing.  Used by pipes.  This
        # should probably be refactored somehow.
        object _fileobj

    cdef _attach_fileobj(self, file)

    cdef _fileno(self)
    cdef _get_socket(self)

    cdef _shutdown(self)

    cdef _listen(self, int backlog)
    cdef _accept(self, UVStream server)

    cdef bint _is_reading(self)
    cdef _start_reading(self)
    cdef _stop_reading(self)
    cdef __reading_started(self)
    cdef __reading_stopped(self)

    cdef inline bint _is_readable(self)
    cdef inline bint _is_writable(self)

    cdef _write(self, object data)
    cdef inline size_t _get_write_buffer_size(self)

    cdef _close(self)

    # The following methods have to be overridden:
    cdef _on_accept(self)
    cdef _on_listen(self)
    cdef _on_read(self, bytes buf)
    cdef _on_eof(self)
    cdef _on_write(self)
    cdef _on_shutdown(self)


cdef class UVStreamServer(UVStream):
    cdef:
        object protocol_factory
        bint opened
        Server _server

    cdef _init(self, Loop loop, object protocol_factory, Server server)

    cdef inline _mark_as_open(self)

    cdef listen(self, int backlog=?)
    cdef _on_listen(self)
    cdef UVTransport _make_new_transport(self, object protocol)
