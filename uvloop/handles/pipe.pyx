cdef __pipe_init_uv_handle(UVStream handle, Loop loop):
    cdef int err

    handle._handle = <uv.uv_handle_t*>PyMem_RawMalloc(sizeof(uv.uv_pipe_t))
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
    fileno = handle._fileno()
    return PseudoSocket(uv.AF_UNIX, uv.SOCK_STREAM, 0, fileno)


@cython.no_gc_clear
cdef class UnixServer(UVStreamServer):

    @staticmethod
    cdef UnixServer new(Loop loop, object protocol_factory, Server server,
                        object backlog,
                        object ssl,
                        object ssl_handshake_timeout,
                        object ssl_shutdown_timeout):

        cdef UnixServer handle
        handle = UnixServer.__new__(UnixServer)
        handle._init(loop, protocol_factory, server, backlog,
                     ssl, ssl_handshake_timeout, ssl_shutdown_timeout)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef _new_socket(self):
        return __pipe_get_socket(<UVSocketHandle>self)

    cdef _open(self, int sockfd):
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

    cdef _open(self, int sockfd):
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

    cdef _open(self, int sockfd):
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

    def __cinit__(self):
        self.disconnect_listener_inited = False
        self.disconnect_listener.data = NULL

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

    cdef _start_reading(self):
        # A custom implementation for monitoring for EOF:
        # libuv since v1.23.1 prohibits using uv_read_start on
        # write-only FDs, so we use a throw-away uv_poll_t handle
        # for that purpose, as suggested in
        # https://github.com/libuv/libuv/issues/2058.

        cdef int err

        if not self.disconnect_listener_inited:
            err = uv.uv_poll_init(self._loop.uvloop,
                                  &self.disconnect_listener,
                                  self._fileno())
            if err < 0:
                raise convert_error(err)
            self.disconnect_listener.data = <void*>self
            self.disconnect_listener_inited = True

        err = uv.uv_poll_start(&self.disconnect_listener,
                               uv.UV_READABLE | uv.UV_DISCONNECT,
                               __on_write_pipe_poll_event)
        if err < 0:
            raise convert_error(err)

    cdef _stop_reading(self):
        cdef int err
        if not self.disconnect_listener_inited:
            return
        err = uv.uv_poll_stop(&self.disconnect_listener)
        if err < 0:
            raise convert_error(err)

    cdef _close(self):
        if self.disconnect_listener_inited:
            self.disconnect_listener.data = NULL
            uv.uv_close(<uv.uv_handle_t *>(&self.disconnect_listener), NULL)
            self.disconnect_listener_inited = False

        UVStream._close(self)

    cdef _new_socket(self):
        return __pipe_get_socket(<UVSocketHandle>self)

    cdef _open(self, int sockfd):
        __pipe_open(<UVStream>self, sockfd)

    def pause_reading(self):
        raise NotImplementedError

    def resume_reading(self):
        raise NotImplementedError


cdef void __on_write_pipe_poll_event(uv.uv_poll_t* handle,
                                     int status, int events) with gil:
    cdef WriteUnixTransport tr

    if handle.data is NULL:
        return

    tr = <WriteUnixTransport>handle.data
    if tr._closed:
        return

    if events & uv.UV_DISCONNECT:
        try:
            tr._stop_reading()
            tr._on_eof()
        except BaseException as ex:
            tr._fatal_error(ex, False)


cdef class _PipeConnectRequest(UVRequest):
    cdef:
        UnixTransport transport
        uv.uv_connect_t _req_data

    def __cinit__(self, loop, transport):
        self.request = <uv.uv_req_t*> &self._req_data
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
        wrapper.transport._fatal_error(ex, False)
    finally:
        wrapper.on_done()
