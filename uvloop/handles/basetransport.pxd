cdef class UVBaseTransport(UVHandle):

    cdef:
        readonly bint _closing

        bint _flow_control_enabled
        bint _protocol_connected
        bint _protocol_paused
        object _protocol_data_received
        size_t _high_water
        size_t _low_water

        # Points to a Python file-object that should be closed
        # when the transport is closing.  Used by pipes.  This
        # should probably be refactored somehow.
        object _fileobj

        object __cached_socket

        object _protocol
        Server _server
        object _waiter

        dict _extra_info

        uint32_t _conn_lost

    cdef inline _set_write_buffer_limits(self, int high=*, int low=*)
    cdef inline _maybe_pause_protocol(self)
    cdef inline _maybe_resume_protocol(self)

    cdef inline _schedule_call_connection_made(self)
    cdef inline _schedule_call_connection_lost(self, exc)

    cdef _call_connection_made(self)
    cdef _call_connection_lost(self, exc)

    # Overloads of UVHandle methods:
    cdef _fatal_error(self, exc, throw, reason=?)
    cdef _close(self)

    cdef inline _fileno(self)
    cdef inline _attach_fileobj(self, file)

    cdef inline _get_socket(self)

    cdef inline _set_server(self, Server server)
    cdef inline _set_waiter(self, object waiter)
    cdef inline _set_protocol(self, object protocol)

    cdef inline _init_protocol(self)
    cdef inline _add_extra_info(self, str name, object obj)

    # === overloads ===

    cdef _new_socket(self)
    cdef size_t _get_write_buffer_size(self)

    cdef bint _is_reading(self)
    cdef _start_reading(self)
    cdef _stop_reading(self)
