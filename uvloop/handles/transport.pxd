cdef class UVTransport(UVStream):
    cdef:
        bint eof
        bint reading

        size_t _high_water
        size_t _low_water
        bint _flow_control_enabled
        bint _protocol_paused

        bint con_closed_scheduled

        object _protocol
        object _protocol_data_received

        Server _server

    cdef _set_protocol(self, object protocol)
    cdef _set_write_buffer_limits(self, int high=*, int low=*)
    cdef _maybe_pause_protocol(self)
    cdef _maybe_resume_protocol(self)
    cdef _call_connection_lost(self, exc)
    cdef _schedule_call_connection_lost(self, exc)

    # Implementations and overloads of UVStream methods:
    cdef _on_accept(self)
    cdef _on_read(self, bytes buf)
    cdef _on_eof(self)
    cdef _on_write(self)
    cdef _write(self, object data)
    cdef _close(self)

    # Overloads of UVHandle methods:
    cdef _fatal_error(self, exc, throw)
