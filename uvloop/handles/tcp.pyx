cdef __tcp_init_uv_handle(UVStream handle, Loop loop):
    cdef int err

    handle._handle = <uv.uv_handle_t*> \
                        PyMem_Malloc(sizeof(uv.uv_tcp_t))
    if handle._handle is NULL:
        handle._abort_init()
        raise MemoryError()

    err = uv.uv_tcp_init(handle._loop.uvloop, <uv.uv_tcp_t*>handle._handle)
    if err < 0:
        handle._abort_init()
        raise convert_error(err)

    handle._finish_init()


cdef __tcp_bind(UVStream handle, system.sockaddr* addr, unsigned int flags=0):
    cdef int err
    err = uv.uv_tcp_bind(<uv.uv_tcp_t *>handle._handle,
                         addr, flags)
    if err < 0:
        exc = convert_error(err)
        raise exc


cdef __tcp_open(UVStream handle, int sockfd):
    cdef int err
    err = uv.uv_tcp_open(<uv.uv_tcp_t *>handle._handle,
                         <uv.uv_os_sock_t>sockfd)
    if err < 0:
        exc = convert_error(err)
        raise exc


@cython.no_gc_clear
cdef class UVTCPServer(UVStreamServer):

    @staticmethod
    cdef UVTCPServer new(Loop loop, object protocol_factory, Server server):
        cdef UVTCPServer handle
        handle = UVTCPServer.__new__(UVTCPServer)
        handle._init(loop, protocol_factory, server)
        __tcp_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef open(self, int sockfd):
        self._ensure_alive()
        try:
            __tcp_open(<UVStream>self, sockfd)
        except Exception as exc:
            self._fatal_error(exc, True)
        else:
            self._mark_as_open()

    cdef bind(self, system.sockaddr* addr, unsigned int flags=0):
        self._ensure_alive()
        try:
            __tcp_bind(<UVStream>self, addr, flags)
        except Exception as exc:
            self._fatal_error(exc, True)
        else:
            self._mark_as_open()

    cdef UVTransport _make_new_transport(self, object protocol):
        cdef UVTCPTransport tr
        tr = UVTCPTransport.new(self._loop, protocol, self._server)
        return <UVTransport>tr


@cython.no_gc_clear
cdef class UVTCPTransport(UVTransport):

    @staticmethod
    cdef UVTCPTransport new(Loop loop, object protocol, Server server):
        cdef UVTCPTransport handle
        handle = UVTCPTransport.__new__(UVTCPTransport)
        handle._init(loop, protocol, server)
        __tcp_init_uv_handle(<UVStream>handle, loop)
        return handle

    cdef bind(self, system.sockaddr* addr, unsigned int flags=0):
        self._ensure_alive()
        __tcp_bind(<UVStream>self, addr, flags)

    cdef open(self, int sockfd):
        self._ensure_alive()
        __tcp_open(<UVStream>self, sockfd)

    cdef connect(self, system.sockaddr* addr, object callback):
        cdef _TCPConnectRequest req
        req = _TCPConnectRequest(self._loop, self, callback)
        req.connect(addr)


cdef class _TCPConnectRequest(UVRequest):
    cdef:
        object callback
        UVTCPTransport transport

    def __cinit__(self, loop, transport, callback):
        self.request = <uv.uv_req_t*> PyMem_Malloc(sizeof(uv.uv_connect_t))
        if self.request is NULL:
            self.on_done()
            raise MemoryError()
        self.request.data = <void*>self

        self.transport = transport
        self.callback = callback

    cdef connect(self, system.sockaddr* addr):
        cdef int err
        err = uv.uv_tcp_connect(<uv.uv_connect_t*>self.request,
                                <uv.uv_tcp_t*>self.transport._handle,
                                addr,
                                __tcp_connect_callback)
        if err < 0:
            exc = convert_error(err)
            self.on_done()
            raise exc


cdef void __tcp_connect_callback(uv.uv_connect_t* req, int status) with gil:
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

