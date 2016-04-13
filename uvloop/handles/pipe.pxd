cdef class UVPipeServer(UVStreamServer):

    cdef bind(self, str path)
    cdef open(self, int sockfd)

    @staticmethod
    cdef UVPipeServer new(Loop loop, object protocol_factory, Server server,
                          object ssl)


cdef class UVPipeTransport(UVTransport):

    @staticmethod
    cdef UVPipeTransport new(Loop loop, object protocol, Server server,
                             object waiter)

    cdef open(self, int sockfd)
    cdef connect(self, char* addr)


cdef class UVReadPipeTransport(UVReadTransport):

    @staticmethod
    cdef UVReadPipeTransport new(Loop loop, object protocol, Server server,
                                 object waiter)

    cdef open(self, int sockfd)


cdef class UVWritePipeTransport(UVWriteTransport):

    @staticmethod
    cdef UVWritePipeTransport new(Loop loop, object protocol, Server server,
                                  object waiter)

    cdef open(self, int sockfd)
