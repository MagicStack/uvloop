# cython: language_level=3


from . cimport uv
from .loop cimport Loop

from cpython.mem cimport PyMem_Malloc, PyMem_Free


cdef class Async:
    def __cinit__(self, Loop loop, object callback):
        self.handle = <uv.uv_async_t*> \
                            PyMem_Malloc(sizeof(uv.uv_async_t))

        self.handle.data = <void*> self
        self.callback = callback

        uv.uv_async_init(loop.loop, self.handle, cb_async_callback)

    def __dealloc__(self):
        PyMem_Free(self.handle)

    cdef void send(self):
        uv.uv_async_send(self.handle)


cdef void cb_async_callback(uv.uv_async_t* handle):
    cdef Async async_ = <Async> handle.data
    async_.callback()
