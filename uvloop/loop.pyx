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
from cpython.pythread cimport PyThread_get_thread_ident


@cython.no_gc_clear
cdef class Loop:
    def __cinit__(self):
        self.loop = <uv.uv_loop_t*> \
                            PyMem_Malloc(sizeof(uv.uv_loop_t))
        self.loop.data = <void*> self
        self._closed = 0
        self._debug = 0
        self._thread_id = 0
        self._running = 0

        uv.uv_loop_init(self.loop)

        # Seems that Cython still can't cleanup module state
        # on its finalization (in Python 3 at least).
        # If a ref from *this* module to asyncio isn't cleared,
        # the policy won't be properly destroyed, hence the
        # loop won't be properly destroyed, hence some warnings
        # might not be shown at all.
        self._asyncio = __import__('asyncio')
        self._asyncio_Task = self._asyncio.Task

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

        self._last_error = None

        self._ready = collections.deque()
        self._ready_len = 0

        self._make_partial = functools.partial

    def _on_wake(self):
        if self._ready_len > 0 and not self.handler_idle.running:
            self.handler_idle.start()

    def _on_sigint(self):
        self._last_error = KeyboardInterrupt()
        self._stop()

    def _on_idle(self):
        cdef int i, ntodo
        cdef object popleft = self._ready.popleft

        ntodo = len(self._ready)
        for i from 0 <= i < ntodo:
            handler = <Handle> popleft()
            if handler.cancelled == 0:
                handler._run()

        self._ready_len = len(self._ready)
        if self._ready_len == 0 and self.handler_idle.running:
            self.handler_idle.stop()

    cdef _stop(self):
        uv.uv_stop(self.loop)

    cdef _run(self, uv.uv_run_mode mode):
        if self._closed == 1:
            raise RuntimeError('unable to start the loop; it was closed')

        if self._running == 1:
            raise RuntimeError('Event loop is running.')

        self._thread_id = PyThread_get_thread_ident()
        self._running = 1
        uv.uv_run(self.loop, mode)
        self._thread_id = 0
        self._running = 0

        if self._last_error is not None:
            last_error = self._last_error
            self.close()
            raise last_error

    cdef _close(self):
        if self._running == 1:
            raise RuntimeError("Cannot close a running event loop")
        if self._closed == 0:
            self._closed = 1

            self._ready.clear()
            self._ready_len = 0
            self._last_error = None

            uv.uv_loop_close(self.loop)

    cdef uint64_t _time(self):
        return uv.uv_now(self.loop)

    cdef _call_soon(self, object callback):
        handle = Handle(self, callback)
        self._ready.append(handle)
        self._ready_len += 1;
        if not self.handler_idle.running:
            self.handler_idle.start()
        return handle

    cdef _call_later(self, uint64_t delay, object callback):
        return TimerHandle(self, callback, delay)

    cdef _handle_uvcb_exception(self, object ex):
        if isinstance(ex, Exception):
            self.call_exception_handler({'exception': ex})
        else:
            # BaseException
            self._last_error = ex
            # Exit ASAP
            self._stop()

    cdef _check_closed(self):
        if self._closed == 1:
            raise RuntimeError('Event loop is closed')

    cdef _check_thread(self):
        if self._thread_id == 0:
            return
        cdef long thread_id = PyThread_get_thread_ident()
        if thread_id != self._thread_id:
            raise RuntimeError(
                "Non-thread-safe operation invoked on an event loop other "
                "than the current one")

    # Public API

    def __repr__(self):
        return ('<%s running=%s closed=%s debug=%s>'
                % (self.__class__.__name__, self.is_running(),
                   self.is_closed(), self.get_debug()))

    def call_soon(self, callback, *args):
        self._check_closed()
        if self._debug == 1:
            self._check_thread()
        if len(args):
            callback = self._make_partial(callback, *args)
        return self._call_soon(callback)

    def call_soon_threadsafe(self, callback, *args):
        self._check_closed()
        if len(args):
            callback = self._make_partial(callback, *args)
        handle = self._call_soon(callback)
        self.handler_async.send()
        return handle

    def call_later(self, delay, callback, *args):
        self._check_closed()
        if self._debug == 1:
            self._check_thread()
        cdef uint64_t when = <uint64_t>(delay * 1000)
        if len(args):
            callback = self._make_partial(callback, *args)
        return self._call_later(when, callback)

    def time(self):
        return self._time() / 1000

    def stop(self):
        self._call_soon(lambda: self._stop())

    def run_forever(self):
        self._check_closed()
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

    def is_running(self):
        if self._running == 0:
            return False
        else:
            return True

    def is_closed(self):
        if self._closed == 0:
            return False
        else:
            return True

    def create_task(self, coro):
        self._check_closed()

        return self._asyncio_Task(coro, loop=self)

    def run_until_complete(self, future):
        self._check_closed()

        new_task = not isinstance(future, self._asyncio.Future)
        future = self._asyncio.ensure_future(future, loop=self)
        if new_task:
            # An exception is raised if the future didn't complete, so there
            # is no need to log the "destroy pending task" message
            future._log_destroy_pending = False

        done_cb = lambda fut: self.stop()

        future.add_done_callback(done_cb)
        try:
            self.run_forever()
        except:
            if new_task and future.done() and not future.cancelled():
                # The coroutine raised a BaseException. Consume the exception
                # to not log a warning, the caller doesn't have access to the
                # local task.
                future.exception()
            raise
        future.remove_done_callback(done_cb)
        if not future.done():
            raise RuntimeError('Event loop stopped before Future completed.')

        return future.result()

    def call_exception_handler(self, context):
        print("!!! EXCEPTION HANDLER !!!", context, flush=True)


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
