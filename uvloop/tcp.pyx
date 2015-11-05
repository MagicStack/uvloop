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
            raise UVError.from_error(err)

        self.opened = 0

    cdef inline ensure_open(self):
        self.ensure_alive()
        if self.opened == 0:
            raise RuntimeError(
                'unable to perform operation on {!r}; '
                'the TCP handler is not open'.format(self))

    cdef enable_nodelay(self):
        cdef int err
        self.ensure_open()
        err = uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self.handle, 1)
        if err < 0:
            raise UVError.from_error(err)

    cdef disable_nodelay(self):
        cdef int err
        self.ensure_open()
        err = uv.uv_tcp_nodelay(<uv.uv_tcp_t *>self.handle, 0)
        if err < 0:
            raise UVError.from_error(err)

    cdef open(self, int sockfd):
        cdef int err
        self.ensure_alive()
        err = uv.uv_tcp_open(<uv.uv_tcp_t *>self.handle, sockfd)
        if err < 0:
            raise UVError.from_error(err)
        self.opened = 1
