cdef class UnixServer(UVStreamServer):

    cdef bind(self, str path)

    @staticmethod
    cdef UnixServer new(Loop loop, object protocol_factory, Server server,
                        object backlog,
                        object ssl,
                        object ssl_handshake_timeout,
                        object ssl_shutdown_timeout)


cdef class UnixTransport(UVStream):

    @staticmethod
    cdef UnixTransport new(Loop loop, object protocol, Server server,
                           object waiter)

    cdef connect(self, char* addr)


cdef class ReadUnixTransport(UVStream):

    @staticmethod
    cdef ReadUnixTransport new(Loop loop, object protocol, Server server,
                               object waiter)


cdef class WriteUnixTransport(UVStream):

    cdef:
        uv.uv_poll_t disconnect_listener
        bint disconnect_listener_inited

    @staticmethod
    cdef WriteUnixTransport new(Loop loop, object protocol, Server server,
                                object waiter)
