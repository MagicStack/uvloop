@cython.no_gc_clear
cdef class UVBaseTransport(UVSocketHandle):

    def __cinit__(self):
        # Flow control
        self._high_water = FLOW_CONTROL_HIGH_WATER
        self._low_water = FLOW_CONTROL_LOW_WATER

        self._protocol = None
        self._protocol_connected = 0
        self._protocol_paused = 0
        self._protocol_data_received = None

        self._server = None
        self._waiter = None
        self._extra_info = None

        self._conn_lost = 0

        self._closing = 0

    cdef size_t _get_write_buffer_size(self):
        return 0

    cdef inline _schedule_call_connection_made(self):
        self._loop._call_soon_handle(
            new_MethodHandle(self._loop,
                             "UVTransport._call_connection_made",
                             <method_t>self._call_connection_made,
                             self))

    cdef inline _schedule_call_connection_lost(self, exc):
        self._loop._call_soon_handle(
            new_MethodHandle1(self._loop,
                              "UVTransport._call_connection_lost",
                              <method1_t>self._call_connection_lost,
                              self, exc))

    cdef _fatal_error(self, exc, throw, reason=None):
        # Overload UVHandle._fatal_error

        self._force_close(exc)

        if not isinstance(exc, (BrokenPipeError,
                                ConnectionResetError,
                                ConnectionAbortedError)):

            if throw or self._loop is None:
                raise exc

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

    cdef inline _set_write_buffer_limits(self, int high=-1, int low=-1):
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

    cdef inline _maybe_pause_protocol(self):
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

    cdef inline _maybe_resume_protocol(self):
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

    cdef _wakeup_waiter(self):
        if self._waiter is not None:
            if not self._waiter.cancelled():
                self._waiter.set_result(True)
            self._waiter = None

    cdef _call_connection_made(self):
        cdef Py_ssize_t _loop_ready_len
        if self._protocol is None:
            raise RuntimeError(
                'protocol is not set, cannot call connection_made()')

        _loop_ready_len = self._loop._ready_len

        # Set _protocol_connected to 1 before calling "connection_made":
        # if transport is aborted or closed, "connection_lost" will
        # still be scheduled.
        self._protocol_connected = 1

        try:
            self._protocol.connection_made(self)
        except:
            self._wakeup_waiter()
            raise

        if self._closing:
            # This might happen when "transport.abort()" is called
            # from "Protocol.connection_made".
            self._wakeup_waiter()
            return

        if _loop_ready_len == self._loop._ready_len:
            # No new calls were scheduled by 'protocol.connection_made',
            # so it's safe to start reading right now.
            self._start_reading()
        else:
            # In asyncio we'd just call start_reading() right after we
            # call protocol.connection_made().  However, that breaks
            # SSLProtocol in uvloop, which does some initialization
            # with loop.call_soon in its connection_made.  It appears,
            # that uvloop can call protocol.data_received() *before* it
            # calls the handlers that connection_made set up.
            # That's why we're using another call_soon here.
            self._loop._call_soon_handle(
                new_MethodHandle(self._loop,
                                 "UVTransport._start_reading",
                                 <method_t>self._start_reading,
                                 self))

        self._wakeup_waiter()

    cdef _call_connection_lost(self, exc):
        if self._waiter is not None:
            # This shouldn't ever happen!
            self._loop.call_exception_handler({
                'message': 'waiter is not None in {}._call_connection_lost'.
                    format(self.__class__.__name__)
            })
            if not self._waiter.done():
                self._waiter.set_exception(exc)
            self._waiter = None

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

            self._close()

            server = self._server
            if server is not None:
                (<Server>server)._detach()
                self._server = None

    cdef inline _set_server(self, Server server):
        self._server = server
        (<Server>server)._attach()

    cdef inline _set_waiter(self, object waiter):
        if waiter is not None and not isfuture(waiter):
            raise TypeError(
                'invalid waiter object {!r}, expected asyncio.Future'.
                    format(waiter))

        self._waiter = waiter

    cdef inline _set_protocol(self, object protocol):
        self._protocol = protocol
        # Store a reference to the bound method directly
        try:
            self._protocol_data_received = protocol.data_received
        except AttributeError:
            pass

    cdef inline _init_protocol(self):
        self._loop._track_transport(self)
        if self._protocol is None:
            raise RuntimeError('invalid _init_protocol call')
        self._schedule_call_connection_made()

    cdef inline _add_extra_info(self, str name, object obj):
        if self._extra_info is None:
            self._extra_info = {}
        self._extra_info[name] = obj

    cdef bint _is_reading(self):
        raise NotImplementedError

    cdef _start_reading(self):
        raise NotImplementedError

    cdef _stop_reading(self):
        raise NotImplementedError

    # === Public API ===

    property _paused:
        # Used by SSLProto.  Might be removed in the future.
        def __get__(self):
            return bool(not self._is_reading())

    def get_protocol(self):
        return self._protocol

    def set_protocol(self, protocol):
        self._set_protocol(protocol)

    def _force_close(self, exc):
        # Used by SSLProto.  Might be removed in the future.
        if self._conn_lost or self._closed:
            return
        if not self._closing:
            self._closing = 1
            self._stop_reading()
        self._conn_lost += 1
        self._schedule_call_connection_lost(exc)

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
