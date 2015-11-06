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

        client = UVServerTransport(self.loop, self)
        client._accept()
        self.loop._track_handle(client) # XXX


cdef class UVServerTransport(UVTCPBase):
    def __cinit__(self, Loop loop, UVTCPServer server):
        self.server = server

    cdef _accept(self):
        cdef int err
        self.ensure_alive()

        err = uv.uv_accept(<uv.uv_stream_t*>self.server.handle,
                           <uv.uv_stream_t*>self.handle)
        if err < 0:
            raise UVError.from_error(err)

        self.opened = 1
        self._start_reading()

    cdef _start_reading(self):
        cdef int err
        self.ensure_alive()

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

        if self.opened != 1:
            raise RuntimeError(
                'cannot UVServerTransport.stop_reading; opened=0')

        err = uv.uv_read_stop(<uv.uv_stream_t*>self.handle)
        if err < 0:
            raise UVError.from_error(err)

    cdef _on_data_recv(self, bytes buf):
        # print('>>>>>>>', buf)
        self._write(buf, None)

    cdef _on_eof(self):
        # print("EOF")
        self.close()

    cdef _write(self, object data, object callback):
        cdef:
            int err
            WriteContext* ctx

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

    cdef _on_data_written(self, object callback):
        if callback is not None:
            callback()

    cdef on_close(self):
        UVHandle.on_close(self)
        self.loop._untrack_handle(self) # XXX?

    # Public API

    def pause_reading(self):
        self._pause_reading()

    def resume_reading(self):
        self._start_reading()


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
