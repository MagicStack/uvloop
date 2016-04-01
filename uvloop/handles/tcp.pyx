cdef __init_tcp_uv_handle(UVStream handle, Loop loop):
    cdef int err

    handle._handle = <uv.uv_handle_t*> \
                        PyMem_Malloc(sizeof(uv.uv_tcp_t))
    if handle._handle is NULL:
        handle._close()
        raise MemoryError()

    err = uv.uv_tcp_init(handle._loop.uvloop, <uv.uv_tcp_t*>handle._handle)
    if err < 0:
        __cleanup_handle_after_init(<UVHandle>handle)
        raise convert_error(err)

    handle._handle.data = <void*> handle


@cython.no_gc_clear
cdef class UVTCPServer(UVStreamServer):

    @staticmethod
    cdef UVTCPServer new(Loop loop, object protocol_factory, Server server):
        cdef UVTCPServer handle
        handle = UVTCPServer.__new__(UVTCPServer)
        handle._init(loop, protocol_factory, server)
        __init_tcp_uv_handle(<UVStream>handle, loop)
        return handle

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
        __init_tcp_uv_handle(<UVStream>handle, loop)
        return handle
