cdef __init_pipe_uv_handle(UVStream handle, Loop loop):
    cdef int err

    handle._handle = <uv.uv_handle_t*> \
                        PyMem_Malloc(sizeof(uv.uv_pipe_t))
    if handle._handle is NULL:
        handle._close()
        raise MemoryError()

    # Initialize pipe handle with ipc=0.
    # ipc=1 means that libuv will use recvmsg/sendmsg
    # instead of recv/send.
    err = uv.uv_pipe_init(handle._loop.uvloop,
                          <uv.uv_pipe_t*>handle._handle,
                          0)
    if err < 0:
        __cleanup_handle_after_init(<UVHandle>handle)
        raise convert_error(err)

    handle._handle.data = <void*> handle


@cython.no_gc_clear
cdef class UVPipeServer(UVStreamServer):

    @staticmethod
    cdef UVPipeServer new(Loop loop, object protocol_factory, Server server):
        cdef UVPipeServer handle
        handle = UVPipeServer.__new__(UVPipeServer)
        handle._init(loop, protocol_factory, server)
        __init_pipe_uv_handle(<UVStream>handle, loop)
        return handle

    cdef bind(self, str path):
        cdef int err
        self._ensure_alive()
        err = uv.uv_pipe_bind(<uv.uv_pipe_t *>self._handle,
                              path.encode())
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return
        self.opened = 1

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
        __init_pipe_uv_handle(<UVStream>handle, loop)
        return handle
