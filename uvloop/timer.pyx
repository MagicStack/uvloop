# cython: language_level=3


from libc.stdint cimport uint64_t

from . cimport uv
from .loop cimport Loop

from cpython.mem cimport PyMem_Malloc, PyMem_Free


cdef class Timer:
    def __cinit__(self, Loop loop, object callback, uint64_t timeout):
        self.handle = <uv.uv_timer_t*> \
                            PyMem_Malloc(sizeof(uv.uv_timer_t))

        self.handle.data = <void*> self
        self.callback = callback

        uv.uv_timer_init(loop.loop, self.handle)

        self.running = 0
        self.timeout = timeout

    def __dealloc__(self):
        try:
            self.stop()
        finally:
            PyMem_Free(self.handle)

    cdef stop(self):
        if self.running == 1:
            uv.uv_timer_stop(self.handle)
            self.running = 0

    cdef start(self):
        if self.running == 0:
            uv.uv_timer_start(self.handle, cb_timer_callback, self.timeout, 0)
            self.running = 1


cdef void cb_timer_callback(uv.uv_timer_t* handle):
    cdef Timer timer = <Timer> handle.data
    timer.running = 0
    timer.callback()
