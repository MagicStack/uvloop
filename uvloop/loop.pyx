# cython: language_level=3

import collections
import signal
import time
import types

cimport cython

from . cimport uv

from .async_ cimport Async
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

        self.handler_async = Async(self, self._on_wake)

        self.handler_idle = Idle(self, self._on_idle)

        self.handler_sigint = Signal(self, self._on_sigint, signal.SIGINT)
        self.handler_sigint.start()

        self.last_error = None

        self.callbacks = collections.deque()

    def _on_wake(self):
        if len(self.callbacks) > 0:
            self.handler_idle.start()

    def _on_sigint(self):
        self.last_error = KeyboardInterrupt()
        uv.uv_stop(self.loop)

    def _on_idle(self):
        cdef int i, ntodo
        cdef object popleft = self.callbacks.popleft

        ntodo = len(self.callbacks)
        for i from 0 <= i < ntodo:
            handler = <Handle> popleft()
            if handler.cancelled == 0:
                handler._run()

        if len(self.callbacks) == 0:
            self.handler_idle.stop()

    def __dealloc__(self):
        try:
            self._close()
        finally:
            PyMem_Free(self.loop)

    cdef _run(self, uv.uv_run_mode mode):
        if self.closed:
            raise RuntimeError('unable to start the loop; it was closed')

        uv.uv_run(self.loop, mode)

        if self.last_error is not None:
            raise self.last_error

    cdef _close(self):
        if self.closed == 0:
            uv.uv_loop_close(self.loop)
            self.closed = 1

    cdef _time(self):
        return uv.uv_now(self.loop)

    cdef _call_soon(self, callback, args):
        handle = Handle(callback, args)
        self.callbacks.append(handle)
        self.handler_idle.start()
        return handle

    # Public API

    def call_soon(self, callback, *args):
        return self._call_soon(callback, args)

    def call_soon_threadsafe(self, callback, *args):
        handle = self._call_soon(callback, args)
        self.handler_async.send()
        return handle

    def time(self):
        return self._time()

    def run(self):
        self._run(uv.UV_RUN_DEFAULT)

    def close(self):
        self._close()


@cython.freelist(100)
cdef class Handle:
    cdef:
        object callback
        object args
        int cancelled

    def __cinit__(self, callback, args):
        self.callback = callback
        self.args = args
        self.cancelled = 0

    cpdef cancel(self):
        self.cancelled = 1

    cdef _run(self):
        if self.args is None:
            self.callback()
        else:
            self.callback(*self.args)
