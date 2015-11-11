@cython.internal
cdef class UVHandle:
    def __cinit__(self, Loop loop, *_):
        self.closed = 0
        self.closing = 0
        self.handle = NULL
        self.loop = loop
        loop.__track_handle__(self)

    def __dealloc__(self):
        if self.handle is not NULL:
            if self.closed == 0:
                raise RuntimeError(
                    'Unable to deallocate handle for {!r} (not closed)'.format(
                        self))
            PyMem_Free(self.handle)
            self.handle = NULL

    cdef inline ensure_alive(self):
        if self.closed == 1 or self.closing == 1 or self.handle is NULL:
            raise RuntimeError(
                'unable to perform operation on {!r}; '
                'the handler is closed'.format(self))

    cdef void close(self):
        if self.closed == 1 or self.closing == 1:
            return

        IF DEBUG:
            if self.handle is NULL:
                raise RuntimeError(
                    '{}.close: .handle is NULL'.format(
                        self.__class__.__name__))

            if self.handle.data is NULL:
                raise RuntimeError(
                    '{}.close: .handle.data is NULL'.format(
                        self.__class__.__name__))

            if <UVHandle>self.handle.data is not self:
                raise RuntimeError(
                    '{}.close: .handle.data is not handle'.format(
                        self.__class__.__name__))

            if uv.uv_is_closing(self.handle):
                raise RuntimeError(
                    '{}.close: uv_is_closing() is true'.format(
                        self.__class__.__name__))

        self.closing = 1
        uv.uv_close(self.handle, __uvhandle_close_cb) # void; no exceptions

    def __repr__(self):
        return '<{} closed={} closing={} {:#x}>'.format(
            self.__class__.__name__,
            self.closed,
            self.closing,
            id(self))


cdef void __uvhandle_close_cb(uv.uv_handle_t* handle) with gil:
    cdef UVHandle h = <UVHandle>handle.data
    h.closed = 1
    h.closing = 0
    h.loop.__untrack_handle__(h) # void; no exceptions
