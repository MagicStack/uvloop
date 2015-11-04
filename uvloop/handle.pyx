# cython: language_level=3


from . cimport uv

from cpython.mem cimport PyMem_Malloc, PyMem_Free


cdef class Handle:
    def __cinit__(self):
        self.closed = 0
        self.handle = NULL

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
        if self.closed == 1:
            return
        if self.handle is NULL or self.handle.data is NULL:
            return
        if uv.uv_is_closing(self.handle):
            return
        uv.uv_close(self.handle, cb_handle_close_cb) # void; no exceptions

    cdef void on_close(self):
        pass


cdef void cb_handle_close_cb(uv.uv_handle_t* handle):
    cdef Handle h = <Handle>handle.data
    h.closed = 1
    h.on_close()
