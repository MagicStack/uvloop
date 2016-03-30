@cython.no_gc_clear
cdef class UVTransport(UVStream):
    def __cinit__(self):
        self._protocol = None
        self._protocol_data_received = None

        self.eof = 0
        self.reading = 0
        self.con_closed_scheduled = 0

        # Flow control
        self._flow_control_enabled = 1
        self._protocol_paused = 0
        self._high_water = FLOW_CONTROL_HIGH_WATER
        self._low_water = FLOW_CONTROL_LOW_WATER

        self.host_server = None

    cdef _set_protocol(self, object protocol):
        self._protocol = protocol

        # Store a reference to the bound method directly
        self._protocol_data_received = protocol.data_received

    cdef _on_accept(self):
        # Implementation for UVStream._on_accept

        self._start_reading()
        self._loop.call_soon(self._protocol.connection_made, self)

    cdef _on_read(self, bytes buf):
        # Implementation for UVStream._on_read

        self._protocol_data_received(buf)

    cdef _on_eof(self):
        # Implementation for UVStream._on_eof

        keep_open = self._protocol.eof_received()
        if keep_open:
            self._stop_reading()
        else:
            self.close()

    cdef _write(self, object data):
        # Overloads UVStream._write
        UVStream._write(self, data)
        self._maybe_pause_protocol()

    cdef _on_write(self):
        # Implementation for UVStream._on_write
        self._maybe_resume_protocol()

    cdef _set_write_buffer_limits(self, int high=-1, int low=-1):
        if high == -1:
            if low == -1:
                high = FLOW_CONTROL_HIGH_WATER
            else:
                high = FLOW_CONTROL_LOW_WATER

        if low == -1:
            low = high // 4

        if not high >= low >= 0:
            raise ValueError('high (%r) must be >= low (%r) must be >= 0' %
                             (high, low))

        self._high_water = high
        self._low_water = low

        self._maybe_pause_protocol()
        self._maybe_resume_protocol()

    cdef _maybe_pause_protocol(self):
        if not self._flow_control_enabled:
            return

        cdef:
            size_t size = self._get_write_buffer_size()

        if size <= self._high_water:
            return

        if not self._protocol_paused:
            self._protocol_paused = 1
            try:
                self._protocol.pause_writing()
            except Exception as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.pause_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self._protocol,
                })

    cdef _maybe_resume_protocol(self):
        if not self._flow_control_enabled:
            return

        cdef:
            size_t size = self._get_write_buffer_size()

        if self._protocol_paused and size <= self._low_water:
            self._protocol_paused = 0
            try:
                self._protocol.resume_writing()
            except Exception as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.resume_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self._protocol,
                })

    cdef _call_connection_lost(self, exc):
        try:
            if self._protocol is not None:
                self._protocol.connection_lost(exc)
        finally:
            self._protocol = None
            self._protocol_data_received = None

            # Although it's likely that the handler has been
            # closed already (by _fatal_error, for instance),
            # we want to make sure that it's closed.
            self._close()

            server = self.host_server
            if server is not None:
                server._detach()
                self.host_server = None

    cdef _schedule_call_connection_lost(self, exc):
        if self.con_closed_scheduled:
            return
        self.con_closed_scheduled = 1

        self._loop._call_soon_handle(
            new_MethodHandle1(self._loop,
                              "UVServerTransport._call_connection_lost",
                              <method1_t*>&self._call_connection_lost,
                              self, exc))

    cdef _fatal_error(self, exc, throw):
        # Overloads UVHandle._fatal_error
        self._schedule_call_connection_lost(exc)
        UVHandle._fatal_error(<UVHandle>self, exc, throw)

    cdef _close(self):
        try:
            if self._is_alive():
                self._schedule_call_connection_lost(None)
        finally:
            UVStream._close(<UVStream>self)

    # Public API

    property _closing:
        def __get__(self):
            return (<UVHandle>self)._closed

    def is_closing(self):
        return (<UVHandle>self)._closed

    def write(self, object buf):
        self._write(buf)

    def writelines(self, bufs):
        for buf in bufs:
            self._write(buf)

    def write_eof(self):
        if self.eof:
            return
        self.eof = 1

        self._shutdown()

    def can_write_eof(self):
        return True

    def pause_reading(self):
        self._stop_reading()

    def resume_reading(self):
        self._start_reading()

    def get_write_buffer_size(self):
        return self._get_write_buffer_size()

    def set_write_buffer_limits(self, high=None, low=None):
        if high is None:
            high = -1
        if low is None:
            low = -1

        self._set_write_buffer_limits(high, low)

    def get_write_buffer_limits(self):
        return (self._low_water, self._high_water)

    def get_extra_info(self, name, default=None):
        if name == 'socket':
            return self._get_socket()
        if name == 'sockname':
            return self._get_socket().getsockname()
        if name == 'peername':
            try:
                return self._get_socket().getpeername()
            except socket_error:
                return default
        return default

    def abort(self):
        # TODO
        # This is probably correct -- we should close the transport
        # right away
        self._close()

    def close(self):
        # This isn't correct.
        # We should stop reading; if the write-buffer isn't
        # empty - we should let it be sent, and only after
        # that we close
        self._close() # TODO
