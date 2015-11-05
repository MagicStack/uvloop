cdef class UVTCPBase(UVStream):
    cdef:
        int opened
        int flags

    cdef enable_nodelay(self)
    cdef disable_nodelay(self)


cdef class UVTCPServer(UVTCPBase):
    cdef:
        object protocol_factory

    cdef set_protocol_factory(self, object protocol_factory)

    cdef open(self, int sockfd)
    cdef bind(self, uv.sockaddr* addr, unsigned int flags=*)
    cdef listen(self, int backlog=*)

    cdef _new_client(self)


cdef class UVServerTransport(UVTCPBase):
    cdef:
        UVTCPServer server

    cdef _start_reading(self)
    cdef _stop_reading(self)

    cdef _accept(self)
    cdef _on_data_recv(self, bytes buf)
    cdef _on_eof(self)

    cdef _write(self, object data, object callback)
    cdef _on_data_written(self, object callback)
