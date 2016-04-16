cdef class UVStreamServer(UVStream):
    cdef:
        object ssl
        object protocol_factory
        bint opened

    cdef _init(self, Loop loop, object protocol_factory, Server server,
               object ssl)

    cdef inline _mark_as_open(self)

    cdef listen(self, int backlog=?)
    cdef _on_listen(self)
    cdef UVStream _make_new_transport(self, object protocol, object waiter)
