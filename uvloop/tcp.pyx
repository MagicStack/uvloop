cdef class UVTCP(UVStream):
    def __cinit__(self, Loop loop):
        cdef int err

        self.handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_tcp_t))
        if self.handle is NULL:
            raise MemoryError()

        self.handle.data = <void*> self

        err = uv.uv_tcp_init(loop.loop, <uv.uv_tcp_t*>self.handle)
        if err < 0:
            loop._handle_uv_error(err)

    cdef enable_nodelay(self):
        self.ensure_alive()
        uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self.handle, 1)

    cdef disable_nodelay(self):
        self.ensure_alive()
        uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self.handle, 0)
