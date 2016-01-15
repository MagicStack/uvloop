cdef class UVTcpStream(UVStream):
    cdef:
        bint opened
        int flags

    cdef _init(self)

    cdef _set_nodelay(self, bint flag)
    cdef _set_keepalive(self, bint flag, unsigned int delay)


cdef class UVTCPServer(UVTcpStream):
    cdef:
        object protocol_factory
        Server host_server

    cdef _init(self)
    cdef _set_protocol_factory(self, object protocol_factory)

    cdef open(self, int sockfd)
    cdef bind(self, system.sockaddr* addr, unsigned int flags=*)

    cdef listen(self, int backlog=*)
    cdef _on_listen(self)

    @staticmethod
    cdef UVTCPServer new(Loop loop, object protocol_factory, Server server)


cdef class UVServerTransport(UVTcpStream):
    cdef:
        Server host_server

        bint eof
        bint reading

        object protocol
        object protocol_data_received

        bint flow_control_enabled
        bint protocol_paused

        size_t high_water
        size_t low_water

    cdef _init(self)
    cdef _set_protocol(self, object protocol)

    cdef _start_reading(self)
    cdef _stop_reading(self)

    cdef _on_read(self, bytes buf)
    cdef _on_eof(self)
    cdef _on_accept(self)
    cdef _on_write(self)

    cdef _write(self, object data, object callback)

    cdef inline size_t _get_write_buffer_size(self)
    cdef _set_write_buffer_limits(self, int high=*, int low=*)
    cdef _maybe_pause_protocol(self)
    cdef _maybe_resume_protocol(self)

    cdef _call_connection_lost(self, exc)

    @staticmethod
    cdef UVServerTransport new(Loop loop, object protocol, Server server)
