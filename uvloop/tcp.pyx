cdef class UVTCPBase(UVStream):
    def __cinit__(self, Loop loop, *_):
        cdef int err

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_tcp_t))
        if self._handle is NULL:
            self._close()
            raise MemoryError()

        self._handle.data = <void*> self

        err = uv.uv_tcp_init(loop.uvloop, <uv.uv_tcp_t*>self._handle)
        if err < 0:
            self._close()
            raise convert_error(err)

        self.opened = 0

    cdef enable_nodelay(self):
        cdef int err
        self._ensure_alive()
        err = uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self._handle, 1)
        if err < 0:
            self._close()
            raise convert_error(err)

    cdef disable_nodelay(self):
        cdef int err
        self._ensure_alive()
        err = uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self._handle, 0)
        if err < 0:
            self._close()
            raise convert_error(err)


cdef class UVTCPServer(UVTCPBase):
    def __cinit__(self, *_):
        self.protocol_factory = None

    cdef set_protocol_factory(self, object protocol_factory):
        if self.protocol_factory is not None:
            raise RuntimeError('can only set protocol_factory once')
        self.protocol_factory = protocol_factory

    cdef open(self, int sockfd):
        cdef int err
        self._ensure_alive()
        err = uv.uv_tcp_open(<uv.uv_tcp_t *>self._handle, sockfd)
        if err < 0:
            self._close()
            raise convert_error(err)
        self.opened = 1

    cdef bind(self, system.sockaddr* addr, unsigned int flags=0):
        cdef int err
        self._ensure_alive()
        err = uv.uv_tcp_bind(<uv.uv_tcp_t *>self._handle,
                             addr, flags)
        if err < 0:
            self._close()
            raise convert_error(err)
        self.opened = 1

    cdef listen(self, int backlog=100):
        if self.protocol_factory is None:
            raise RuntimeError('unable to listen(); no protocol_factory')

        if self.opened != 1:
            raise RuntimeError('unopened UVTCPServer')

        self._listen(backlog)

    cdef _on_listen(self):
        protocol = self.protocol_factory()
        client = UVServerTransport(self._loop, protocol)
        client._accept(<UVStream>self)


cdef class UVServerTransport(UVTCPBase):
    def __cinit__(self, Loop loop, object protocol not None):
        self.protocol = protocol
        self.protocol_data_received = protocol.data_received

        self.eof = 0
        self.reading = 0

        # Flow control
        self.flow_control_enabled = 1
        self.protocol_paused = 0
        self.high_water = FLOW_CONTROL_HIGH_WATER
        self.low_water = FLOW_CONTROL_LOW_WATER

    cdef _on_accept(self):
        self.opened = 1
        self._start_reading()
        self._loop.call_soon(self.protocol.connection_made, self)

    cdef _on_read(self, bytes buf):
        self.protocol_data_received(buf)

    cdef _on_eof(self):
        keep_open = self.protocol.eof_received()
        if not keep_open:
            self._close()

    cdef _write(self, object data, object callback):
        UVStream._write(self, data, callback)
        self._maybe_pause_protocol()

    cdef _on_write(self):
        self._maybe_resume_protocol()

    cdef inline size_t _get_write_buffer_size(self):
        if self._handle is NULL:
            return 0
        return (<uv.uv_stream_t*>self._handle).write_queue_size

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

        self._ensure_alive()

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

        self._ensure_alive()

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

    # Public API

    property _closing:
        def __get__(self):
            # "self._closing" refers to "UVHandle._closing" cdef
            return (<UVHandle>self)._closing or (<UVHandle>self)._closed

    def is_closing(self):
        return (<UVHandle>self)._closing or (<UVHandle>self)._closed

    def write(self, object buf):
        self._write(buf, None)

    def writelines(self, bufs):
        for buf in bufs:
            self._write(buf, None)

    def write_eof(self):
        if self.eof == 1:
            return
        self.eof = 1

        self._shutdown()

    def can_write_eof(self):
        return True

    def is_flow_control_enabled(self):
        if self.flow_control_enabled == 1:
            return True
        else:
            return False

    def enable_flow_control(self):
        self.flow_control_enabled = 1
        self._maybe_pause_protocol()

    def disable_flow_control(self):
        if self.flow_control_enabled == 0:
            return

        try:
            if self.protocol_paused == 1:
                self.protocol_paused = 0
                self.prototol.resume_writing()
        finally:
            self.flow_control_enabled = 0

    def pause_reading(self):
        self._pause_reading()

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
        return default

    def abort(self):
        self._close() # TODO?
