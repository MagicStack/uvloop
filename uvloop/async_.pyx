cdef class UVAsync(UVHandle):
    def __cinit__(self, Loop loop, object callback):
        cdef int err

        self.handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_async_t))
        if self.handle is NULL:
            raise MemoryError()

        self.handle.data = <void*> self

        err = uv.uv_async_init(loop.loop,
                               <uv.uv_async_t*>self.handle,
                               cb_async_callback)
        if err < 0:
            loop._handle_uv_error(err)

        self.callback = callback

    cdef send(self):
        cdef int err

        self.ensure_alive()

        err = uv.uv_async_send(<uv.uv_async_t*>self.handle)
        if err < 0:
            self.loop._handle_uv_error(err)


cdef void cb_async_callback(uv.uv_async_t* handle):
    cdef UVAsync async_ = <UVAsync> handle.data
    try:
        async_.callback()
    except BaseException as ex:
        async_.loop._handle_uvcb_exception(ex)
