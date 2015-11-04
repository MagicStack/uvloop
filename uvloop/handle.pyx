cdef class BaseHandle:
    def __cinit__(self, Loop loop, *_):
        self.closed = 0
        self.handle = NULL
        self.loop = loop

    def __del__(self):
        self.close()

    def __dealloc__(self):
        if self.handle is not NULL:
            if self.closed == 0:
                raise RuntimeError(
                    'Unable to deallocate handle for {!r} (not closed)'.format(
                        self))
            PyMem_Free(self.handle)
            self.handle = NULL

    cdef close(self):
        if (self.closed == 1 or
            self.handle is NULL or
            self.handle.data is NULL or
            uv.uv_is_closing(self.handle)):
            return

        Py_INCREF(self) # Make sure the handle won't die *during* closing
        uv.uv_close(self.handle, cb_handle_close_cb) # void; no exceptions

    cdef on_close(self):
        pass


cdef void cb_handle_close_cb(uv.uv_handle_t* handle):
    cdef BaseHandle h = <BaseHandle>handle.data
    h.closed = 1
    try:
        h.on_close()
    except BaseException as ex:
        h.loop._handle_uvcb_exception(ex)
    finally:
        Py_DECREF(h)
