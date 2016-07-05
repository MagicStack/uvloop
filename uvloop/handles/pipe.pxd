cdef class UnixServer(UVStreamServer):

    cdef:
        uv.uv_pipe_t _handle_data

    cdef bind(self, str path)
    cdef open(self, int sockfd)

    @staticmethod
    cdef UnixServer new(Loop loop, object protocol_factory, Server server,
                        object ssl)


cdef class UnixTransport(UVStream):

    cdef:
        uv.uv_pipe_t _handle_data

    @staticmethod
    cdef UnixTransport new(Loop loop, object protocol, Server server,
                           object waiter)

    cdef open(self, int sockfd)
    cdef connect(self, char* addr)


cdef class ReadUnixTransport(UVStream):

    cdef:
        uv.uv_pipe_t _handle_data

    @staticmethod
    cdef ReadUnixTransport new(Loop loop, object protocol, Server server,
                               object waiter)

    cdef open(self, int sockfd)


cdef class WriteUnixTransport(UVStream):

    cdef:
        uv.uv_pipe_t _handle_data

    @staticmethod
    cdef WriteUnixTransport new(Loop loop, object protocol, Server server,
                                object waiter)

    cdef open(self, int sockfd)
