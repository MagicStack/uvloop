cdef class UVTCPServer(UVStreamServer):
    cdef open(self, int sockfd)
    cdef bind(self, system.sockaddr* addr, unsigned int flags=*)

    @staticmethod
    cdef UVTCPServer new(Loop loop, object protocol_factory, Server server,
                         object ssl)


cdef class UVTCPTransport(UVStream):
    cdef bind(self, system.sockaddr* addr, unsigned int flags=*)
    cdef open(self, int sockfd)
    cdef connect(self, system.sockaddr* addr)

    @staticmethod
    cdef UVTCPTransport new(Loop loop, object protocol, Server server,
                            object waiter)
