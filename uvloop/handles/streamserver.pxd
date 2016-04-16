cdef class UVStreamServer(UVSocketHandle):
    cdef:
        object ssl
        object protocol_factory
        bint opened
        Server _server

    # All "inline" methods are final

    cdef inline _init(self, Loop loop, object protocol_factory,
                      Server server, object ssl)

    cdef inline _mark_as_open(self)

    cdef inline listen(self, int backlog)
    cdef inline _on_listen(self)

    cdef UVStream _make_new_transport(self, object protocol, object waiter)
