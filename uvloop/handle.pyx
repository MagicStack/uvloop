@cython.internal
cdef class UVHandle:
    """A base class for all libuv handles.

    Automatically manages memory deallocation and closing.

    Important: call "_ensure_alive()" before calling any libuv
    functions on your handles.
    """

    def __cinit__(self, Loop loop, *_):
        self._closed = 0
        self._closing = 0
        self._handle = NULL
        self._loop = loop
        loop.__track_handle__(self)

    def __dealloc__(self):
        if self._handle is not NULL:
            if self._closed == 0:
                raise RuntimeError(
                    'Unable to deallocate handle for {!r} (not closed)'.format(
                        self))
            PyMem_Free(self._handle)
            self._handle = NULL

    cdef inline _ensure_alive(self):
        if self._closed == 1 or self._closing == 1 or self._handle is NULL:
            raise RuntimeError(
                'unable to perform operation on {!r}; '
                'the handler is closed'.format(self))

    cdef _close(self):
        if self._closed == 1 or self._closing == 1:
            return

        IF DEBUG:
            if self._handle is NULL:
                raise RuntimeError(
                    '{}.close: ._handle is NULL'.format(
                        self.__class__.__name__))

            if self._handle.data is NULL:
                raise RuntimeError(
                    '{}.close: ._handle.data is NULL'.format(
                        self.__class__.__name__))

            if <UVHandle>self._handle.data is not self:
                raise RuntimeError(
                    '{}.close: ._handle.data is not UVHandle'.format(
                        self.__class__.__name__))

            if uv.uv_is_closing(self._handle):
                raise RuntimeError(
                    '{}.close: uv_is_closing() is true'.format(
                        self.__class__.__name__))

        if self._handle is NULL:
            # Shouldn't fail even if called from __cinit__ before the
            # handle is initialized.
            self._closed = 1
            if self._loop.__is_handle_tracked__(self):
                # This can happen if an exception has occurred during
                # Handle.__cinit__.  Since __uv_handle_close_cb isn't
                # going to be called, we need to untrack the handle
                # here.
                self._loop.__untrack_handle__(self)
        else:
            self._closing = 1
            uv.uv_close(self._handle, __uv_handle_close_cb) # void; no errors

    def __repr__(self):
        return '<{} closed={} closing={} {:#x}>'.format(
            self.__class__.__name__,
            self._closed,
            self._closing,
            id(self))


cdef void __uv_handle_close_cb(uv.uv_handle_t* handle) with gil:
    cdef UVHandle h = <UVHandle>handle.data
    h._closed = 1
    h._closing = 0
    h._loop.__untrack_handle__(h) # void; no errors
