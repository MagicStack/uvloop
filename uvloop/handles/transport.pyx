@cython.no_gc_clear
cdef class UVTransport(UVStream):

    def __cinit__(self):
        self._protocol = None
        self._protocol_data_received = None
        self._protocol_connected = 0
        self._protocol_paused = 0

        self._eof = 0
        self._closing = 0
        self._conn_lost = 0

        # Flow control
        self._flow_control_enabled = 1
        self._high_water = FLOW_CONTROL_HIGH_WATER
        self._low_water = FLOW_CONTROL_LOW_WATER

        self._server = None
        self._extra_info = None
        self._fileobj = None

    cdef _init(self, Loop loop, object protocol, Server server):
        self._start_init(loop)
        self._set_protocol(protocol)
        if server is not None:
            self._set_server(server)

    cdef _set_server(self, Server server):
        self._server = server
        (<Server>server)._attach()

    cdef _set_protocol(self, object protocol):
        self._protocol = protocol

        # Store a reference to the bound method directly
        try:
            self._protocol_data_received = protocol.data_received
        except AttributeError:
            pass

    cdef _init_protocol(self, waiter):
        if self._protocol is None:
            raise RuntimeError('invalid _init_protocol call')

        self._schedule_call_connection_made()

        if waiter is not None:
            IF DEBUG:
                if not isinstance(waiter, aio_Future):
                    raise TypeError('invalid waiter')
            self._loop.call_soon(_set_result_unless_cancelled, waiter, True)

    cdef _add_extra_info(self, str name, object obj):
        if self._extra_info is None:
            self._extra_info = {}
        self._extra_info[name] = obj

    cdef _on_accept(self):
        # Implementation for UVStream._on_accept
        self._schedule_call_connection_made()

    cdef _on_read(self, bytes buf):
        # Implementation for UVStream._on_read

        self._protocol_data_received(buf)

    cdef _on_eof(self):
        # Implementation for UVStream._on_eof

        try:
            meth = self._protocol.eof_received
        except AttributeError:
            keep_open = False
        else:
            keep_open = meth()

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
        if not self._get_write_buffer_size():
            if self._closing:
                self._call_connection_lost(None)
            elif self._eof:
                self._shutdown()

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

    cdef _call_connection_made(self):
        if self._protocol is None:
            raise RuntimeError(
                'protocol is not set, cannot call connection_made()')

        self._protocol.connection_made(self)
        self._protocol_connected = 1

        # only start reading when connection_made() has been called
        self._start_reading()

    cdef _schedule_call_connection_made(self):
        self._loop._call_soon_handle(
            new_MethodHandle(self._loop,
                             "UVTransport._call_connection_made",
                             <method_t*>&self._call_connection_made,
                             self))

    cdef _call_connection_lost(self, exc):
        if self._closed:
            # The handle is closed -- likely, _call_connection_lost
            # was already called before.
            return

        try:
            if self._protocol_connected:
                self._protocol.connection_lost(exc)
        finally:
            self._protocol = None
            self._protocol_data_received = None

            server = self._server
            if server is not None:
                (<Server>server)._detach()
                self._server = None

            self._close()

    cdef _schedule_call_connection_lost(self, exc):
        self._loop._call_soon_handle(
            new_MethodHandle1(self._loop,
                              "UVTransport._call_connection_lost",
                              <method1_t*>&self._call_connection_lost,
                              self, exc))

    cdef _fatal_error(self, exc, throw, reason=None):
        # Overload UVHandle._fatal_error

        if not isinstance(exc, (BrokenPipeError,
                                ConnectionResetError,
                                ConnectionAbortedError)):

            msg = 'Fatal error on transport {}'.format(
                    self.__class__.__name__)
            if reason is not None:
                msg = '{} ({})'.format(msg, reason)

            self._loop.call_exception_handler({
                'message': msg,
                'exception': exc,
                'transport': self,
                'protocol': self._protocol,
            })

        self._force_close(exc)

    cdef _force_close(self, exc):
        if self._conn_lost or self._closed:
            return
        if not self._closing:
            self._closing = 1
            self._stop_reading()
        self._conn_lost += 1
        self._schedule_call_connection_lost(exc)

    # Public API

    def abort(self):
        self._force_close(None)

    def close(self):
        if self._closing or self._closed:
            return

        self._closing = 1
        self._stop_reading()

        if not self._get_write_buffer_size():
            # The write buffer is empty
            self._conn_lost += 1
            self._schedule_call_connection_lost(None)

    def is_closing(self):
        return self._closing

    def write(self, object buf):
        self._ensure_alive()

        if self._eof:
            raise RuntimeError('Cannot call write() after write_eof()')
        if not buf:
            return
        if self._conn_lost:
            self._conn_lost += 1
            return
        self._write(buf)
        self._maybe_pause_protocol()

    def writelines(self, bufs):
        for buf in bufs:
            self.write(buf)

    def write_eof(self):
        self._ensure_alive()

        if self._eof:
            return

        self._eof = 1
        if not self._get_write_buffer_size():
            self._shutdown()

    def can_write_eof(self):
        return True

    def pause_reading(self):
        self._ensure_alive()

        if self._closing:
            raise RuntimeError('Cannot pause_reading() when closing')
        if not self._is_reading():
            raise RuntimeError('Already paused')
        self._stop_reading()

    def resume_reading(self):
        self._ensure_alive()

        if self._is_reading():
            raise RuntimeError('Not paused')
        if self._closing:
            return
        self._start_reading()

    def get_write_buffer_size(self):
        return self._get_write_buffer_size()

    def set_write_buffer_limits(self, high=None, low=None):
        self._ensure_alive()

        if high is None:
            high = -1
        if low is None:
            low = -1

        self._set_write_buffer_limits(high, low)

    def get_write_buffer_limits(self):
        return (self._low_water, self._high_water)

    def get_extra_info(self, name, default=None):
        if self._extra_info is not None and name in self._extra_info:
            return self._extra_info[name]
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


@cython.no_gc_clear
cdef class UVReadTransport(UVTransport):
    # No multiple-inheritance for extension classes -- let's
    # just mask the methods we don't need

    def get_write_buffer_limits(self):
        raise NotImplementedError

    def set_write_buffer_limits(self, high=None, low=None):
        raise NotImplementedError

    def get_write_buffer_size(self):
        raise NotImplementedError

    def write(self, data):
        raise NotImplementedError

    def writelines(self, list_of_data):
        raise NotImplementedError

    def write_eof(self):
        raise NotImplementedError

    def can_write_eof(self):
        raise NotImplementedError

    def abort(self):
        raise NotImplementedError


@cython.no_gc_clear
cdef class UVWriteTransport(UVTransport):
    # No multiple-inheritance for extension classes -- let's
    # just mask the methods we don't need

    def pause_reading(self):
        raise NotImplementedError

    def resume_reading(self):
        raise NotImplementedError
