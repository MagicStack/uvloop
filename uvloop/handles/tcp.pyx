cdef __init_tcp_handle(UVStream handle, Loop loop):
    cdef int err

    handle._set_loop(loop)

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
cdef class UVTCPServer(UVStream):
    def __cinit__(self):
        self.protocol_factory = None
        self.host_server = None
        self.opened = 0

    @staticmethod
    cdef UVTCPServer new(Loop loop, object protocol_factory, Server server):
        cdef UVTCPServer handle
        handle = UVTCPServer.__new__(UVTCPServer)
        __init_tcp_handle(<UVStream>handle, loop)

        if handle.protocol_factory is not None:
            raise RuntimeError('can only set protocol_factory once')
        handle.protocol_factory = protocol_factory

        handle.host_server = server
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

    cdef listen(self, int backlog=100):
        if self.protocol_factory is None:
            raise RuntimeError('unable to listen(); no protocol_factory')

        if self.opened != 1:
            raise RuntimeError('unopened UVTCPServer')

        self._listen(backlog)

    cdef _on_listen(self):
        # Implementation for UVStream._on_listen

        protocol = self.protocol_factory()
        client = UVTCPTransport.new(self._loop, protocol, self.host_server)
        client._accept(<UVStream>self)


@cython.no_gc_clear
cdef class UVTCPTransport(UVTransport):
    @staticmethod
    cdef UVTCPTransport new(Loop loop, object protocol, Server server):
        cdef UVTCPTransport handle
        handle = UVTCPTransport.__new__(UVTCPTransport)
        __init_tcp_handle(<UVStream>handle, loop)
        handle._set_protocol(protocol)
        handle.host_server = server
        if server is not None:
            (<Server>server)._attach()
        return handle
