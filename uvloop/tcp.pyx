ctypedef struct WriteContext:
    uv.uv_write_t req
    uv.uv_buf_t uv_buf
    Py_buffer py_buf
    PyObject* callback
    PyObject* transport
    Py_ssize_t len


cdef class UVTCPBase(UVStream):
    def __cinit__(self, Loop loop, *_):
        cdef int err

        self.handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_tcp_t))
        if self.handle is NULL:
            raise MemoryError()

        self.handle.data = <void*> self

        err = uv.uv_tcp_init(loop.loop, <uv.uv_tcp_t*>self.handle)
        if err < 0:
            raise UVError.from_error(err)

        self.opened = 0

    cdef enable_nodelay(self):
        cdef int err
        self.ensure_alive()
        err = uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self.handle, 1)
        if err < 0:
            raise UVError.from_error(err)

    cdef disable_nodelay(self):
        cdef int err
        self.ensure_alive()
        err = uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self.handle, 0)
        if err < 0:
            raise UVError.from_error(err)


cdef class UVTCPServer(UVTCPBase):
    def __cinit__(self, *_):
        self.protocol_factory = None

    cdef set_protocol_factory(self, object protocol_factory):
        if self.protocol_factory is not None:
            raise RuntimeError('can only set protocol_factory once')
        self.protocol_factory = protocol_factory

    cdef open(self, int sockfd):
        cdef int err
        self.ensure_alive()
        err = uv.uv_tcp_open(<uv.uv_tcp_t *>self.handle, sockfd)
        if err < 0:
            raise UVError.from_error(err)
        self.opened = 1

    cdef bind(self, uv.sockaddr* addr, unsigned int flags=0):
        cdef int err
        self.ensure_alive()
        err = uv.uv_tcp_bind(<uv.uv_tcp_t *>self.handle,
                             addr, flags)
        if err < 0:
            raise UVError.from_error(err)
        self.opened = 1

    cdef listen(self, int backlog=100):
        cdef int err
        self.ensure_alive()

        if self.protocol_factory is None:
            raise RuntimeError('unable to listen(); no protocol_factory')

        if self.opened != 1:
            raise RuntimeError('unopened UVTCPServer')

        err = uv.uv_listen(<uv.uv_stream_t*> self.handle,
                           backlog,
                           __server_listen_cb)
        if err < 0:
            raise UVError.from_error(err)

    cdef _new_client(self):
        protocol = self.protocol_factory()

        client = UVServerTransport(self.loop, self, protocol)
        client._accept()
        self.loop._track_handle(client) # XXX


cdef class UVServerTransport(UVTCPBase):
    def __cinit__(self, Loop loop, UVTCPServer server,
                  object protocol not None):

        self.server = server

        self.protocol = protocol
        self.protocol_data_received = protocol.data_received

        self.eof = 0
        self.reading = 0

        # Flow control
        self.flow_control_enabled = 1
        self.protocol_paused = 0
        self.high_water = 64 * 1024 # TODO: constants
        self.low_water = (64 * 1024) // 4

    cdef _accept(self):
        cdef int err
        self.ensure_alive()

        err = uv.uv_accept(<uv.uv_stream_t*>self.server.handle,
                           <uv.uv_stream_t*>self.handle)
        if err < 0:
            raise UVError.from_error(err)

        self.opened = 1
        self._start_reading()

        self.loop.call_soon(self.protocol.connection_made, self)

    cdef _start_reading(self):
        cdef int err
        self.ensure_alive()

        if self.reading == 1:
            raise RuntimeError('Not paused')
        self.reading = 1

        if self.opened != 1:
            raise RuntimeError(
                'cannot UVServerTransport.start_reading; opened=0')

        err = uv.uv_read_start(<uv.uv_stream_t*>self.handle,
                               __alloc_cb,
                               __server_transport_onread_cb)
        if err < 0:
            raise UVError.from_error(err)

    cdef _stop_reading(self):
        cdef int err
        self.ensure_alive()

        if self.reading == 0:
            raise RuntimeError('Already paused')
        self.reading = 0

        if self.opened != 1:
            raise RuntimeError(
                'cannot UVServerTransport.stop_reading; opened=0')

        err = uv.uv_read_stop(<uv.uv_stream_t*>self.handle)
        if err < 0:
            raise UVError.from_error(err)

    cdef _on_data_recv(self, bytes buf):
        self.protocol_data_received(buf)

    cdef _on_eof(self):
        keep_open = self.protocol.eof_received()
        if not keep_open:
            self.close()

    cdef _on_shutdown(self):
        pass

    cdef _write(self, object data, object callback):
        cdef:
            int err
            WriteContext* ctx

        if self.eof:
            raise RuntimeError('Cannot call write() after write_eof()')

        self.ensure_alive()

        ctx = <WriteContext*> PyMem_Malloc(sizeof(WriteContext))
        if ctx is NULL:
            raise MemoryError()

        try:
            PyObject_GetBuffer(data, &ctx.py_buf, PyBUF_SIMPLE)
        except:
            PyMem_Free(ctx)
            raise

        ctx.transport = <PyObject*>self
        ctx.callback = <PyObject*>callback
        ctx.uv_buf = uv.uv_buf_init(<char*>ctx.py_buf.buf, ctx.py_buf.len)
        ctx.len = ctx.py_buf.len
        ctx.req.data = <void*> ctx

        err = uv.uv_write(&ctx.req,
                          <uv.uv_stream_t*>self.handle,
                          &ctx.uv_buf,
                          1,
                          __server_transport_onwrite_cb)

        if err < 0:
            PyBuffer_Release(&ctx.py_buf)
            raise UVError.from_error(err)
        else:
            Py_INCREF(self)
            Py_INCREF(callback)

        self._maybe_pause_protocol()

    cdef _on_data_written(self, object callback):
        self._maybe_resume_protocol()

        if callback is not None:
            callback()

    cdef inline size_t _get_write_buffer_size(self):
        if self.handle is NULL:
            return 0
        return (<uv.uv_stream_t*>self.handle).write_queue_size

    cdef _set_write_buffer_limits(self, int high=-1, int low=-1):
        if high == -1:
            if low == -1:
                high = 64 * 1024 # TODO: constants
            else:
                high = 4 * low

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

        self.ensure_alive()

        cdef:
            size_t size = self._get_write_buffer_size()

        if size <= self.high_water:
            return

        if self.protocol_paused == 0:
            self.protocol_paused = 1
            try:
                self.protocol.pause_writing()
            except Exception as exc:
                self.loop.call_exception_handler({
                    'message': 'protocol.pause_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self.protocol,
                })

    cdef _maybe_resume_protocol(self):
        if self.flow_control_enabled == 0:
            return

        self.ensure_alive()

        cdef:
            size_t size = self._get_write_buffer_size()

        if self.protocol_paused == 1 and size <= self.low_water:
            self.protocol_paused = 0
            try:
                self.protocol.resume_writing()
            except Exception as exc:
                self.loop.call_exception_handler({
                    'message': 'protocol.resume_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self.protocol,
                })

    cdef on_close(self):
        self.loop._untrack_handle(self) # XXX?

    # Public API

    property _closing:
        def __get__(self):
            return False

    def write(self, object buf):
        self._write(buf, None)

    def writelines(self, bufs):
        for buf in bufs:
            self._write(buf, None)

    def write_eof(self):
        if self.eof == 1:
            return
        self.eof = 1

        cdef int err

        self.shutdown_req.data = <void*> self

        err = uv.uv_shutdown(&self.shutdown_req,
                             <uv.uv_stream_t*> self.handle,
                             __server_transport_shutdown)
        if err < 0:
            raise UVError.from_error(err)

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
        self.close() # TODO?


cdef void __server_listen_cb(uv.uv_stream_t* server_handle,
                             int status) with gil:
    cdef:
        UVTCPServer server = <UVTCPServer> server_handle.data
        UVServerTransport client

    if status < 0:
        exc = UVError.from_error(status)
        server.loop._handle_uvcb_exception(exc)
        return

    try:
        server._new_client()
    except BaseException as exc:
        server.loop._handle_uvcb_exception(exc)


cdef void __alloc_cb(uv.uv_handle_t* uvhandle,
                     size_t suggested_size,
                     uv.uv_buf_t* buf) with gil:
    cdef:
        Loop loop = (<UVHandle>uvhandle.data).loop

    if loop._recv_buffer_in_use == 1:
        buf.len = 0
        exc = RuntimeError('concurrent allocations')
        loop._handle_uvcb_exception(exc)
        return

    loop._recv_buffer_in_use = 1
    buf.base = loop._recv_buffer
    buf.len = sizeof(loop._recv_buffer)


cdef void __server_transport_onread_cb(uv.uv_stream_t* stream,
                                       ssize_t nread,
                                       uv.uv_buf_t* buf) with gil:
    cdef:
        UVServerTransport sc = <UVServerTransport>stream.data
        Loop loop = sc.loop

    loop._recv_buffer_in_use = 0

    if nread == uv.UV_EOF:
        sc._on_eof()
        return

    if nread < 0:
        sc.close() # XXX?

        exc = UVError.from_error(nread)
        sc.loop._handle_uvcb_exception(exc)
        return

    try:
        sc._on_data_recv(loop._recv_buffer[:nread])
    except BaseException as exc:
        loop._handle_uvcb_exception(exc)


cdef void __server_transport_onwrite_cb(uv.uv_write_t* req,
                                        int status) with gil:
    cdef:
        WriteContext* ctx = <WriteContext*> req.data
        UVServerTransport transport = <UVServerTransport>ctx.transport
        object callback = <object>ctx.callback

    try:
        transport._on_data_written(callback)
    except BaseException as exc:
        transport.loop._handle_uvcb_exception(exc)
    finally:
        PyBuffer_Release(&ctx.py_buf)
        Py_XDECREF(ctx.transport)
        Py_XDECREF(ctx.callback)
        PyMem_Free(ctx)


cdef void __server_transport_shutdown(uv.uv_shutdown_t* req,
                                      int status) with gil:

    cdef UVServerTransport transport = <UVServerTransport> req.data

    if status < 0:
        transport.loop._handle_uvcb_exception(status)
        return

    transport._on_shutdown()
