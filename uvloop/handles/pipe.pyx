cdef __pipe_init_uv_handle(UVStream handle, Loop loop):
    cdef int err

    handle._handle = <uv.uv_handle_t*> \
                        PyMem_Malloc(sizeof(uv.uv_pipe_t))
    if handle._handle is NULL:
        handle._abort_init()
        raise MemoryError()

    # Initialize pipe handle with ipc=0.
    # ipc=1 means that libuv will use recvmsg/sendmsg
    # instead of recv/send.
    err = uv.uv_pipe_init(handle._loop.uvloop,
                          <uv.uv_pipe_t*>handle._handle,
                          0)
    if err < 0:
        handle._abort_init()
        raise convert_error(err)

    handle._finish_init()


cdef __pipe_open(UVStream handle, int fd):
    cdef int err
    err = uv.uv_pipe_open(<uv.uv_pipe_t *>handle._handle,
                          <uv.uv_file>fd)
    if err < 0:
        exc = convert_error(err)
        raise exc


cdef __pipe_get_socket(UVSocketHandle handle):
    return socket_socket(uv.AF_UNIX, uv.SOCK_STREAM, 0, handle._fileno())


@cython.no_gc_clear
cdef class UnixServer(UVStreamServer):

    @staticmethod
    cdef UnixServer new(Loop loop, object protocol_factory, Server server,
                          object ssl):

        cdef UnixServer handle
        handle = UnixServer.__new__(UnixServer)
        handle._init(loop, protocol_factory, server, ssl)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef _new_socket(self):
        return __pipe_get_socket(<UVSocketHandle>self)

    cdef open(self, int sockfd):
        self._ensure_alive()
        __pipe_open(<UVStream>self, sockfd)
        self._mark_as_open()

    cdef bind(self, str path):
        cdef int err
        self._ensure_alive()
        err = uv.uv_pipe_bind(<uv.uv_pipe_t *>self._handle,
                              path.encode())
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

        self._mark_as_open()

    cdef UVStream _make_new_transport(self, object protocol, object waiter):
        cdef UnixTransport tr
        tr = UnixTransport.new(self._loop, protocol, self._server, waiter)
        return <UVStream>tr


@cython.no_gc_clear
cdef class UnixTransport(UVStream):

    @staticmethod
    cdef UnixTransport new(Loop loop, object protocol, Server server,
                             object waiter):

        cdef UnixTransport handle
        handle = UnixTransport.__new__(UnixTransport)
        handle._init(loop, protocol, server, waiter)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef _new_socket(self):
        return __pipe_get_socket(<UVSocketHandle>self)

    cdef open(self, int sockfd):
        __pipe_open(<UVStream>self, sockfd)

    cdef connect(self, char* addr):
        cdef _PipeConnectRequest req
        req = _PipeConnectRequest(self._loop, self)
        req.connect(addr)


@cython.no_gc_clear
cdef class ReadUnixTransport(UVStream):

    @staticmethod
    cdef ReadUnixTransport new(Loop loop, object protocol, Server server,
                                 object waiter):
        cdef ReadUnixTransport handle
        handle = ReadUnixTransport.__new__(ReadUnixTransport)
        handle._init(loop, protocol, server, waiter)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef _new_socket(self):
        return __pipe_get_socket(<UVSocketHandle>self)

    cdef open(self, int sockfd):
        __pipe_open(<UVStream>self, sockfd)

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
cdef class WriteUnixTransport(UVStream):

    @staticmethod
    cdef WriteUnixTransport new(Loop loop, object protocol, Server server,
                                  object waiter):
        cdef WriteUnixTransport handle
        handle = WriteUnixTransport.__new__(WriteUnixTransport)

        # We listen for read events on write-end of the pipe. When
        # the read-end is close, the uv_stream_t.read callback will
        # receive an error -- we want to silence that error, and just
        # close the transport.
        handle._close_on_read_error()

        handle._init(loop, protocol, server, waiter)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef _new_socket(self):
        return __pipe_get_socket(<UVSocketHandle>self)

    cdef open(self, int sockfd):
        __pipe_open(<UVStream>self, sockfd)

    def pause_reading(self):
        raise NotImplementedError

    def resume_reading(self):
        raise NotImplementedError


cdef class _PipeConnectRequest(UVRequest):
    cdef:
        UnixTransport transport

    def __cinit__(self, loop, transport):
        self.request = <uv.uv_req_t*> PyMem_Malloc(sizeof(uv.uv_connect_t))
        if self.request is NULL:
            self.on_done()
            raise MemoryError()
        self.request.data = <void*>self
        self.transport = transport

    cdef connect(self, char* addr):
        # uv_pipe_connect returns void
        uv.uv_pipe_connect(<uv.uv_connect_t*>self.request,
                           <uv.uv_pipe_t*>self.transport._handle,
                           addr,
                           __pipe_connect_callback)

cdef void __pipe_connect_callback(uv.uv_connect_t* req, int status) with gil:
    cdef:
        _PipeConnectRequest wrapper
        UnixTransport transport

    wrapper = <_PipeConnectRequest> req.data
    transport = wrapper.transport

    if status < 0:
        exc = convert_error(status)
    else:
        exc = None

    try:
        transport._on_connect(exc)
    except BaseException as ex:
        wrapper.transport._error(ex, False)
    finally:
        wrapper.on_done()

