@cython.final
@cython.internal
cdef class UVAsync(UVHandle):
    def __cinit__(self, Loop loop, object callback):
        cdef int err

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_async_t))
        if self._handle is NULL:
            raise MemoryError()

        self._handle.data = <void*> self

        err = uv.uv_async_init(loop.uvloop,
                               <uv.uv_async_t*>self._handle,
                               __uvasync_callback)
        if err < 0:
            raise convert_error(err)

        self.callback = callback

    cdef send(self):
        cdef int err

        self._ensure_alive()

        err = uv.uv_async_send(<uv.uv_async_t*>self._handle)
        if err < 0:
            raise convert_error(err)


cdef void __uvasync_callback(uv.uv_async_t* handle) with gil:
    cdef UVAsync async_ = <UVAsync> handle.data
    try:
        async_.callback()
    except BaseException as ex:
        async_._loop._handle_uvcb_exception(ex)
