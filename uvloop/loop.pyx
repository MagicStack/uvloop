# cython: language_level=3

import signal
import time

from . cimport uv
from .idle cimport Idle
from .signal cimport Signal

from cpython.mem cimport PyMem_Malloc, PyMem_Free
from cpython.exc cimport PyErr_CheckSignals, PyErr_Occurred


cdef class Loop:
    def __cinit__(self):
        self.loop = <uv.uv_loop_t*> \
                            PyMem_Malloc(sizeof(uv.uv_loop_t))
        self.loop.data = <void*> self
        self.closed = 0

        uv.uv_loop_init(self.loop)

        self.handler_idle = Idle(self, self.on_idle)
        self.handler_idle.start()

        self.handler_sigint = Signal(self, self.on_sigint, signal.SIGINT)
        self.handler_sigint.start()

        self.last_error = None

    def on_sigint(self):
        self.last_error = KeyboardInterrupt()
        uv.uv_stop(self.loop)

    def on_idle(self):
        pass

    def __dealloc__(self):
        try:
            self.close()
        finally:
            PyMem_Free(self.loop)

    cpdef close(self):
        if self.closed == 0:
            uv.uv_loop_close(self.loop)
            self.closed = 1

    cdef _run(self, uv.uv_run_mode mode):
        if self.closed:
            raise RuntimeError('unable to start the loop; it was closed')

        uv.uv_run(self.loop, mode)

        if self.last_error is not None:
            raise self.last_error

    def run(self):
        self._run(uv.UV_RUN_DEFAULT)
