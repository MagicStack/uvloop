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


@cython.no_gc_clear
cdef class UVPipeServer(UVStreamServer):

    @staticmethod
    cdef UVPipeServer new(Loop loop, object protocol_factory, Server server):
        cdef UVPipeServer handle
        handle = UVPipeServer.__new__(UVPipeServer)
        handle._init(loop, protocol_factory, server)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

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

    cdef UVTransport _make_new_transport(self, object protocol):
        cdef UVPipeTransport tr
        tr = UVPipeTransport.new(self._loop, protocol, self._server)
        return <UVTransport>tr


@cython.no_gc_clear
cdef class UVPipeTransport(UVTransport):

    @staticmethod
    cdef UVPipeTransport new(Loop loop, object protocol, Server server):
        cdef UVPipeTransport handle
        handle = UVPipeTransport.__new__(UVPipeTransport)
        handle._init(loop, protocol, server)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef open(self, int sockfd):
        __pipe_open(<UVStream>self, sockfd)

    cdef connect(self, char* addr, object callback):
        cdef _PipeConnectRequest req
        req = _PipeConnectRequest(self._loop, self, callback)
        req.connect(addr)


@cython.no_gc_clear
cdef class UVReadPipeTransport(UVReadTransport):

    @staticmethod
    cdef UVReadPipeTransport new(Loop loop, object protocol, Server server):
        cdef UVReadPipeTransport handle
        handle = UVReadPipeTransport.__new__(UVReadPipeTransport)
        handle._init(loop, protocol, server)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef open(self, int sockfd):
        __pipe_open(<UVStream>self, sockfd)


@cython.no_gc_clear
cdef class UVWritePipeTransport(UVWriteTransport):

    @staticmethod
    cdef UVWritePipeTransport new(Loop loop, object protocol, Server server):
        cdef UVWritePipeTransport handle
        handle = UVWritePipeTransport.__new__(UVWritePipeTransport)
        handle._init(loop, protocol, server)
        __pipe_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef open(self, int sockfd):
        __pipe_open(<UVStream>self, sockfd)


cdef class _PipeConnectRequest(UVRequest):
    cdef:
        object callback
        UVPipeTransport transport

    def __cinit__(self, loop, transport, callback):
        self.request = <uv.uv_req_t*> PyMem_Malloc(sizeof(uv.uv_connect_t))
        if self.request is NULL:
            self.on_done()
            raise MemoryError()
        self.request.data = <void*>self

        self.transport = transport
        self.callback = callback

    cdef connect(self, char* addr):
        # uv_pipe_connect returns void
        uv.uv_pipe_connect(<uv.uv_connect_t*>self.request,
                           <uv.uv_pipe_t*>self.transport._handle,
                           addr,
                           __pipe_connect_callback)

cdef void __pipe_connect_callback(uv.uv_connect_t* req, int status) with gil:
    cdef:
        _TCPConnectRequest wrapper
        object callback

    wrapper = <_TCPConnectRequest> req.data
    callback = wrapper.callback

    if status < 0:
        exc = convert_error(status)
    else:
        exc = None

    try:
        callback(exc)
    except BaseException as ex:
        wrapper.transport._error(ex, False)
    finally:
        wrapper.on_done()

