cdef class UVTCPServer(UVStream):
    cdef:
        object protocol_factory
        Server host_server
        bint opened

    cdef open(self, int sockfd)
    cdef bind(self, system.sockaddr* addr, unsigned int flags=*)
    cdef listen(self, int backlog=*)

    # Overloads of UVStream methods
    cdef _on_listen(self)

    @staticmethod
    cdef UVTCPServer new(Loop loop, object protocol_factory, Server server)


cdef class UVTCPTransport(UVTransport):
    @staticmethod
    cdef UVTCPTransport new(Loop loop, object protocol, Server server)
