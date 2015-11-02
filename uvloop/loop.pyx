# cython: language_level=3


import collections
import functools
import signal
import time
import types

cimport cython

from . cimport uv

from .async_ cimport Async
from .idle cimport Idle
from .signal cimport Signal
from .timer cimport Timer

from libc.stdint cimport uint64_t

from cpython.mem cimport PyMem_Malloc, PyMem_Free
from cpython.exc cimport PyErr_CheckSignals, PyErr_Occurred


@cython.no_gc_clear
cdef class Loop:
    def __cinit__(self):
        self.loop = <uv.uv_loop_t*> \
                            PyMem_Malloc(sizeof(uv.uv_loop_t))
        self.loop.data = <void*> self
        self.closed = 0
        self._debug = 0

        uv.uv_loop_init(self.loop)

        # Seems that Cython still can't cleanup module state
        # on its finalization (in Python 3 at least).
        # If a ref from *this* module to asyncio isn't cleared,
        # the policy won't be properly destroyed, hence the
        # loop won't be properly destroyed, hence some warnings
        # might not be shown at all.
        asyncio = __import__('asyncio')
        self._default_task_constructor = asyncio.Task

    def __dealloc__(self):
        try:
            self._close()
        finally:
            PyMem_Free(self.loop)

    def __init__(self):
        self.handler_async = Async(self, self._on_wake)

        self.handler_idle = Idle(self, self._on_idle)

        self.handler_sigint = Signal(self, self._on_sigint, signal.SIGINT)
        self.handler_sigint.start()

        self.last_error = None

        self.callbacks = collections.deque()

        self.partial = functools.partial

    def _on_wake(self):
        if len(self.callbacks) > 0:
            self.handler_idle.start()

    def _on_sigint(self):
        self.last_error = KeyboardInterrupt()
        self._stop()

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

    cdef _stop(self):
        uv.uv_stop(self.loop)

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

    cdef uint64_t _time(self):
        return uv.uv_now(self.loop)

    cdef _call_soon(self, object callback):
        handle = Handle(self, callback)
        self.callbacks.append(handle)
        self.handler_idle.start()
        return handle

    cdef _call_later(self, uint64_t delay, object callback):
        return TimerHandle(self, callback, delay)

    # Public API

    def call_soon(self, callback, *args):
        if len(args):
            callback = self.partial(callback, *args)
        return self._call_soon(callback)

    def call_soon_threadsafe(self, callback, *args):
        if len(args):
            callback = self.partial(callback, *args)
        handle = self._call_soon(callback)
        self.handler_async.send()
        return handle

    def call_later(self, delay, callback, *args):
        cdef uint64_t when = <uint64_t>(delay * 1000)
        if len(args):
            callback = self.partial(callback, *args)
        return self._call_later(when, callback)

    def time(self):
        return self._time() / 1000

    def stop(self):
        self._call_soon(lambda: self._stop())

    def run_forever(self):
        self._run(uv.UV_RUN_DEFAULT)

    def close(self):
        self._close()

    def get_debug(self):
        if self._debug == 1:
            return True
        else:
            return False

    def set_debug(self, enabled):
        if enabled:
            self._debug = 1
        else:
            self._debug = 0

    def create_task(self, coro):
        return self._default_task_constructor(coro, loop=self)

    def call_exception_handler(self, context):
        print("!!! EXCEPTION HANDLER !!!", context)


@cython.internal
@cython.freelist(100)
cdef class Handle:
    cdef:
        object callback
        int cancelled
        object __weakref__

    def __cinit__(self, Loop loop, object callback):
        self.callback = callback
        self.cancelled = 0

    cpdef cancel(self):
        self.cancelled = 1

    cdef _run(self):
        self.callback()


@cython.internal
@cython.freelist(100)
cdef class TimerHandle:
    cdef:
        object callback
        int cancelled
        Timer timer
        object __weakref__

    def __cinit__(self, Loop loop, object callback, uint64_t delay):
        self.callback = callback
        self.cancelled = 0
        self.timer = Timer(loop, self._run, delay)
        self.timer.start()

    cpdef cancel(self):
        if self.cancelled == 0:
            self.cancelled = 1
            self.timer.stop()

    def _run(self):
        if self.cancelled == 0:
            self.callback()
