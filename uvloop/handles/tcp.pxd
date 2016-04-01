cdef class UVTCPServer(UVStreamServer):
    cdef open(self, int sockfd)
    cdef bind(self, system.sockaddr* addr, unsigned int flags=*)

    @staticmethod
    cdef UVTCPServer new(Loop loop, object protocol_factory, Server server)


cdef class UVTCPTransport(UVTransport):
    @staticmethod
    cdef UVTCPTransport new(Loop loop, object protocol, Server server)
