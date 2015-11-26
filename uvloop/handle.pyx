cdef __NOHANDLE__ = object()


@cython.internal
cdef class UVHandle:
    """A base class for all libuv handles.

    Automatically manages memory deallocation and closing.

    Important:

       1. call "_ensure_alive()" before calling any libuv functions on
          your handles.

       2. call "__ensure_handle_data" in *all* libuv handle callbacks.
    """

    def __cinit__(self, Loop loop, *_):
        self._closed = 0
        self._handle = NULL
        self._loop = loop

    def __dealloc__(self):
        if self._handle is NULL:
            return

        if self._closed == 1:
            # So _handle is not NULL and self._closed == 1?
            raise RuntimeError(
                'UVHandle.__dealloc__: _handle is NULL, _closed == 1')

        # Let's close the handle.
        self._handle.data = <void*> __NOHANDLE__
        uv.uv_close(self._handle, __uv_close_handle_cb) # void; no errors
        self._handle = NULL

    cdef inline bint _is_alive(self):
        return self._closed != 1 and self._handle is not NULL

    cdef inline _ensure_alive(self):
        if self._closed == 1 or self._handle is NULL:
            raise RuntimeError(
                'unable to perform operation on {!r}; '
                'the handler is closed'.format(self))

    cdef _close(self):
        if self._closed == 1:
            return

        self._closed = 1

        if self._handle is NULL:
            return

        IF DEBUG:
            if self._handle.data is NULL:
                raise RuntimeError(
                    '{}._close: _handle.data is NULL'.format(
                        self.__class__.__name__))

            if <object>self._handle.data is not self:
                raise RuntimeError(
                    '{}._close: _handle.data is not UVHandle/self'.format(
                        self.__class__.__name__))

            if uv.uv_is_closing(self._handle):
                raise RuntimeError(
                    '{}._close: uv_is_closing() is true'.format(
                        self.__class__.__name__))

        # We want the handle wrapper (UVHandle) to stay alive until
        # the closing callback fires.
        Py_INCREF(self)
        uv.uv_close(self._handle, __uv_close_handle_cb) # void; no errors

    def __repr__(self):
        return '<{} closed={} {:#x}>'.format(
            self.__class__.__name__,
            self._closed,
            id(self))


cdef void __cleanup_handle_after_init(UVHandle h):
    PyMem_Free(h._handle)
    h._handle = NULL
    h._closed = 1


cdef inline bint __ensure_handle_data(void* data, const char* handle_ctx):
    if data is NULL:
        aio_logger.error('%s called with handle.data == NULL',
                         handle_ctx.decode('latin-1'))
        return 0

    if <object>data is __NOHANDLE__:
        # The underlying UVHandle object was GCed with an open uv_handle_t.
        aio_logger.error('%s called after destroying the UVHandle',
                         handle_ctx.decode('latin-1'))
        return 0

    return 1


cdef void __uv_close_handle_cb(uv.uv_handle_t* handle) with gil:
    cdef:
        UVHandle h
        Loop loop

    if handle.data is NULL:
        # Shouldn't happen.
        loop = <Loop>handle.loop.data
        loop.call_exception_handler({
            'message': 'uv_handle_t.data is NULL in close callback'
        })
    elif <object>handle.data is not __NOHANDLE__:
        h = <UVHandle>handle.data
        h._handle = NULL
        Py_DECREF(h) # Was inc'ed in UVHandle._close

    PyMem_Free(handle)


cdef void __close_all_handles(Loop loop):
    uv.uv_walk(loop.uvloop, __uv_walk_close_all_handles_cb, <void*>loop) # void

cdef void __uv_walk_close_all_handles_cb(uv.uv_handle_t* handle, void* arg):
    cdef:
        Loop loop = <Loop>arg
        UVHandle h

    if uv.uv_is_closing(handle):
        # The handle is closed or is closing.
        return

    if handle.data is NULL:
        # This shouldn't happen. Ever.
        loop.call_exception_handler({
            'message': 'handle.data is NULL in __close_all_handles_cb'
        })
        return

    if <object>handle.data is __NOHANDLE__:
        # And this shouldn't happen too.
        loop.call_exception_handler({
            'message': "handle.data is __NOHANDLE__ yet it's not closing"
        })
        return

    h = <UVHandle>handle.data
    h._close()
