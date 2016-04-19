cdef class UnixServer(UVStreamServer):

    cdef bind(self, str path)
    cdef open(self, int sockfd)

    @staticmethod
    cdef UnixServer new(Loop loop, object protocol_factory, Server server,
                        object ssl)


cdef class UnixTransport(UVStream):

    @staticmethod
    cdef UnixTransport new(Loop loop, object protocol, Server server,
                           object waiter)

    cdef open(self, int sockfd)
    cdef connect(self, char* addr)


cdef class ReadUnixTransport(UVStream):

    @staticmethod
    cdef ReadUnixTransport new(Loop loop, object protocol, Server server,
                               object waiter)

    cdef open(self, int sockfd)


cdef class WriteUnixTransport(UVStream):

    @staticmethod
    cdef WriteUnixTransport new(Loop loop, object protocol, Server server,
                                object waiter)

    cdef open(self, int sockfd)
