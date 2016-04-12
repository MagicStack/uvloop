cdef class UVTransport(UVStream):
    cdef:
        bint _eof
        readonly bint _closing
        dict _extra_info

        size_t _high_water
        size_t _low_water
        bint _flow_control_enabled
        bint _protocol_paused
        bint _protocol_connected
        uint32_t _conn_lost

        object _protocol
        object _protocol_data_received

        Server _server

    cdef _init(self, Loop loop, object protocol, Server server)

    cdef _set_protocol(self, object protocol)
    cdef _set_server(self, Server server)

    cdef _init_protocol(self, waiter)

    cdef _set_write_buffer_limits(self, int high=*, int low=*)
    cdef _maybe_pause_protocol(self)
    cdef _maybe_resume_protocol(self)

    cdef _call_connection_made(self)
    cdef _schedule_call_connection_made(self)

    cdef _call_connection_lost(self, exc)
    cdef _schedule_call_connection_lost(self, exc)

    # Implementations and overloads of UVStream methods:
    cdef _on_accept(self)
    cdef _on_read(self, bytes buf)
    cdef _on_eof(self)
    cdef _on_write(self)
    cdef _write(self, object data)
    cdef _force_close(self, exc)

    # Overloads of UVHandle methods:
    cdef _fatal_error(self, exc, throw, reason=?)

    cdef _add_extra_info(self, str name, object obj)


cdef class UVReadTransport(UVTransport):
    pass


cdef class UVWriteTransport(UVTransport):
    pass
