# cython: language_level=3


from . cimport uv
from .loop cimport Loop

from cpython.mem cimport PyMem_Malloc, PyMem_Free


cdef class Idle:
    def __cinit__(self, Loop loop, object callback):
        self.handle = <uv.uv_idle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_idle_t))

        self.handle.data = <void*> self
        self.callback = callback

        uv.uv_idle_init(loop.loop, self.handle)

        self.running = 0
        self.loop = loop

    def __dealloc__(self):
        try:
            self.stop()
        finally:
            PyMem_Free(self.handle)

    cdef void stop(self):
        if self.running == 1:
            uv.uv_idle_stop(self.handle)
            self.running = 0

    cdef void start(self):
        if self.running == 0:
            uv.uv_idle_start(self.handle, cb_idle_callback)
            self.running = 1


cdef void cb_idle_callback(uv.uv_idle_t* handle):
    cdef Idle idle = <Idle> handle.data
    try:
        idle.callback()
    except BaseException as ex:
        idle.loop._handle_uvcb_exception(ex)
