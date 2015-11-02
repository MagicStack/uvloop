# cython: language_level=3


from . cimport uv
from .loop cimport Loop

from cpython.mem cimport PyMem_Malloc, PyMem_Free


cdef class Signal:
    def __cinit__(self, Loop loop, object callback, int signum):
        self.handle = <uv.uv_signal_t*> \
                            PyMem_Malloc(sizeof(uv.uv_signal_t))

        self.handle.data = <void*> self
        self.callback = callback

        uv.uv_signal_init(loop.loop, self.handle)

        self.running = 0
        self.signum = signum

    def __dealloc__(self):
        try:
            self.stop()
        finally:
            PyMem_Free(self.handle)

    cdef stop(self):
        if self.running == 1:
            uv.uv_signal_stop(self.handle)
            self.running = 0

    cdef start(self):
        uv.uv_signal_start(self.handle, cb_signal_callback, self.signum)
        self.running = 1


cdef void cb_signal_callback(uv.uv_signal_t* handle, int signum):
    cdef Signal sig = <Signal> handle.data
    sig.callback()
