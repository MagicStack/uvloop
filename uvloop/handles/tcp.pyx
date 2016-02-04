@cython.internal
@cython.no_gc_clear
cdef class UVTcpStream(UVStream):
    cdef _init(self):
        cdef int err

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_tcp_t))
        if self._handle is NULL:
            self._close()
            raise MemoryError()

        err = uv.uv_tcp_init(self._loop.uvloop, <uv.uv_tcp_t*>self._handle)
        if err < 0:
            __cleanup_handle_after_init(<UVHandle>self)
            raise convert_error(err)

        self._handle.data = <void*> self
        self.opened = 0

    cdef _set_nodelay(self, bint flag):
        cdef int err
        self._ensure_alive()
        err = uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self._handle, flag)
        if err < 0:
            raise convert_error(err)

    cdef _set_keepalive(self, bint flag, unsigned int delay):
        cdef int err
        self._ensure_alive()
        err = uv.uv_tcp_keepalive(<uv.uv_tcp_t *>self._handle, flag, delay)
        if err < 0:
            raise convert_error(err)


@cython.internal
@cython.no_gc_clear
cdef class UVTCPServer(UVTcpStream):
    cdef _init(self):
        UVTcpStream._init(<UVTcpStream>self)
        self.protocol_factory = None
        self.host_server = None

    @staticmethod
    cdef UVTCPServer new(Loop loop, object protocol_factory, Server server):
        cdef UVTCPServer handle
        handle = UVTCPServer.__new__(UVTCPServer)
        handle._set_loop(loop)
        handle._init()
        handle._set_protocol_factory(protocol_factory)
        handle.host_server = server
        return handle

    cdef _set_protocol_factory(self, object protocol_factory):
        if self.protocol_factory is not None:
            raise RuntimeError('can only set protocol_factory once')
        self.protocol_factory = protocol_factory

    cdef open(self, int sockfd):
        cdef int err
        self._ensure_alive()
        err = uv.uv_tcp_open(<uv.uv_tcp_t *>self._handle,
                             <uv.uv_os_sock_t>sockfd)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return
        self.opened = 1

    cdef bind(self, system.sockaddr* addr, unsigned int flags=0):
        cdef int err
        self._ensure_alive()
        err = uv.uv_tcp_bind(<uv.uv_tcp_t *>self._handle,
                             addr, flags)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return
        self.opened = 1

    cdef listen(self, int backlog=100):
        if self.protocol_factory is None:
            raise RuntimeError('unable to listen(); no protocol_factory')

        if self.opened != 1:
            raise RuntimeError('unopened UVTCPServer')

        self._listen(backlog)

    cdef _on_listen(self):
        protocol = self.protocol_factory()
        client = UVServerTransport.new(self._loop, protocol, self.host_server)
        client._accept(<UVStream>self)


@cython.internal
@cython.no_gc_clear
cdef class UVServerTransport(UVTcpStream):
    cdef _init(self):
        UVTcpStream._init(<UVTcpStream>self)

        self.protocol = None
        self.protocol_data_received = None

        self.eof = 0
        self.reading = 0
        self.con_closed_scheduled = 0

        # Flow control
        self.flow_control_enabled = 1
        self.protocol_paused = 0
        self.high_water = FLOW_CONTROL_HIGH_WATER
        self.low_water = FLOW_CONTROL_LOW_WATER

    @staticmethod
    cdef UVServerTransport new(Loop loop, object protocol, Server server):
        cdef UVServerTransport handle
        handle = UVServerTransport.__new__(UVServerTransport)
        handle._set_loop(loop)
        handle._init()
        handle._set_protocol(protocol)
        handle.host_server = server
        if server is not None:
            (<Server>server)._attach()
        return handle

    cdef _set_protocol(self, object protocol):
        self.protocol = protocol
        self.protocol_data_received = protocol.data_received

    cdef _on_accept(self):
        self.opened = 1
        self._start_reading()
        self._loop.call_soon(self.protocol.connection_made, self)

    cdef _on_read(self, bytes buf):
        self.protocol_data_received(buf)

    cdef _on_eof(self):
        keep_open = self.protocol.eof_received()
        if keep_open:
            self._stop_reading()
        else:
            self._close()

    cdef _write(self, object data):
        UVStream._write(self, data)
        self._maybe_pause_protocol()

    cdef _on_write(self):
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

        self.high_water = high
        self.low_water = low

        self._maybe_pause_protocol()
        self._maybe_resume_protocol()

    cdef _maybe_pause_protocol(self):
        if self.flow_control_enabled == 0:
            return

        cdef:
            size_t size = self._get_write_buffer_size()

        if size <= self.high_water:
            return

        if self.protocol_paused == 0:
            self.protocol_paused = 1
            try:
                self.protocol.pause_writing()
            except Exception as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.pause_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self.protocol,
                })

    cdef _maybe_resume_protocol(self):
        if self.flow_control_enabled == 0:
            return

        cdef:
            size_t size = self._get_write_buffer_size()

        if self.protocol_paused == 1 and size <= self.low_water:
            self.protocol_paused = 0
            try:
                self.protocol.resume_writing()
            except Exception as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.resume_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self.protocol,
                })

    cdef _call_connection_lost(self, exc):
        try:
            if self.protocol is not None:
                self.protocol.connection_lost(exc)
        finally:
            self.protocol = None
            self.protocol_data_received = None

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
        if self.eof == 1:
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
