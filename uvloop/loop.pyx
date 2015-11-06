# cython: language_level=3


cimport cython

from . cimport uv

from libc.stdint cimport uint64_t
from libc.string cimport memset

from cpython cimport PyObject
from cpython cimport PyMem_Malloc, PyMem_Free
from cpython cimport PyErr_CheckSignals, PyErr_Occurred
from cpython cimport PyThread_get_thread_ident
from cpython cimport Py_INCREF, Py_DECREF, Py_XDECREF, Py_XINCREF
from cpython cimport PyObject_GetBuffer, PyBuffer_Release, PyBUF_SIMPLE, \
                     Py_buffer


include "stdlib.pxi"


class LoopError(Exception):
    pass


class UVError(LoopError):

    @staticmethod
    def from_error(int err):
        cdef:
            bytes msg = uv.uv_strerror(err)
            bytes name = uv.uv_err_name(err)

        return LoopError('({}) {}'.format(name.decode('latin-1'),
                                          msg.decode('latin-1')))



@cython.no_gc_clear
cdef class Loop:
    def __cinit__(self):
        self.loop = <uv.uv_loop_t*> \
                            PyMem_Malloc(sizeof(uv.uv_loop_t))
        if self.loop is NULL:
            raise MemoryError()

        self.loop.data = <void*> self
        self._closed = 0
        self._debug = 0
        self._thread_id = 0
        self._running = 0

        self._recv_buffer_in_use = 0

    def __del__(self):
        self._close()

    def __dealloc__(self):
        try:
            if uv.uv_loop_alive(self.loop):
                aio_logger.error(
                    "!!! deallocating event loop with active handles !!!")
        finally:
            PyMem_Free(self.loop)

    def __init__(self):
        cdef int err

        err = uv.uv_loop_init(self.loop)
        if err < 0:
            raise UVError.from_error(err)

        self.handler_async = UVAsync(self, self._on_wake)
        self.handler_idle = UVIdle(self, self._on_idle)
        self.handler_sigint = UVSignal(self, self._on_sigint, uv.SIGINT)
        self.handler_sighup = UVSignal(self, self._on_sighup, uv.SIGHUP)

        self._last_error = None

        self._ready = col_deque()
        self._ready_len = 0

        self._timers = set()
        self._handles = set() # TODO?

    def _on_wake(self):
        if self._ready_len > 0 and not self.handler_idle.running:
            self.handler_idle.start()

    def _on_sigint(self):
        self._last_error = KeyboardInterrupt()
        self._stop()

    def _on_sighup(self):
        self._last_error = SystemExit()
        self._stop()

    def _on_idle(self):
        cdef int i, ntodo
        cdef object popleft = self._ready.popleft

        ntodo = len(self._ready)
        for i from 0 <= i < ntodo:
            handler = <Handle> popleft()
            if handler.cancelled == 0:
                try:
                    handler._run()
                except BaseException as ex:
                    self._handle_uvcb_exception(ex)

        self._ready_len = len(self._ready)
        if self._ready_len == 0 and self.handler_idle.running:
            self.handler_idle.stop()

    cdef _stop(self):
        uv.uv_stop(self.loop)

    cdef _track_handle(self, UVHandle handle):
        self._handles.add(handle)

    cdef _untrack_handle(self, UVHandle handle):
        try:
            self._handles.remove(handle)
        except KeyError:
            pass

    cdef _run(self, uv.uv_run_mode mode):
        cdef int err

        if self._closed == 1:
            raise RuntimeError('unable to start the loop; it was closed')

        if self._running == 1:
            raise RuntimeError('Event loop is running.')

        # reset _last_error
        self._last_error = None

        self._thread_id = PyThread_get_thread_ident()
        self._running = 1

        self.handler_idle.start()
        self.handler_sigint.start()
        self.handler_sighup.start()

        with nogil:
            err = uv.uv_run(self.loop, mode)

        if err < 0:
            raise UVError.from_error(err)

        self.handler_idle.stop()
        self.handler_sigint.stop()
        self.handler_sighup.stop()

        self._thread_id = 0
        self._running = 0

        if self._last_error is not None:
            self.close()
            raise self._last_error

    cdef _close(self):
        cdef int err

        if self._running == 1:
            raise RuntimeError("Cannot close a running event loop")

        if self._closed == 1:
            return

        self._closed = 1

        self.handler_idle.close()
        self.handler_sigint.close()
        self.handler_sighup.close()
        self.handler_async.close()

        if self._timers:
            lst = tuple(self._timers)
            for timer in lst:
                (<TimerHandle>timer).close()

        if self._handles:
            for handle in self._handles:
                (<UVHandle>handle).close()

        # Allow loop to fire "close" callbacks
        with nogil:
            err = uv.uv_run(self.loop, uv.UV_RUN_DEFAULT)

        if err < 0:
            raise UVError.from_error(err)

        err = uv.uv_loop_close(self.loop)
        if err < 0:
            raise UVError.from_error(err)

        self._ready.clear()
        self._ready_len = 0
        self._timers = None

    cdef uint64_t _time(self):
        return uv.uv_now(self.loop)

    cdef _call_soon(self, object callback):
        self._check_closed()
        handle = Handle(self, callback)
        self._ready.append(handle)
        self._ready_len += 1;
        if not self.handler_idle.running:
            self.handler_idle.start()
        return handle

    cdef _call_later(self, uint64_t delay, object callback):
        return TimerHandle(self, callback, delay)

    cdef void _handle_uvcb_exception(self, object ex):
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
        if self._debug == 1:
            self._check_thread()
        if args:
            _cb = callback
            callback = lambda: _cb(*args)
        return self._call_soon(callback)

    def call_soon_threadsafe(self, callback, *args):
        if args:
            _cb = callback
            callback = lambda: _cb(*args)
        handle = self._call_soon(callback)
        self.handler_async.send()
        return handle

    def call_later(self, delay, callback, *args):
        self._check_closed()
        if self._debug == 1:
            self._check_thread()
        cdef uint64_t when = <uint64_t>(delay * 1000)
        if args:
            _cb = callback
            callback = lambda: _cb(*args)
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

        return aio_Task(coro, loop=self)

    def run_until_complete(self, future):
        self._check_closed()

        new_task = not isinstance(future, aio_Future)
        future = aio_ensure_future(future, loop=self)
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

    def getaddrinfo(self, str host, int port, *,
                    int family=0, int type=0, int proto=0, int flags=0):

        return self._getaddrinfo(host, port, family, type, proto, flags, 1)

    cdef _getaddrinfo(self, str host, int port,
                      int family=0, int type=0,
                      int proto=0, int flags=0,
                      int unpack=1):

        fut = aio_Future(loop=self)

        def callback(result):
            if AddrInfo.isinstance(result):
                try:
                    if unpack == 0:
                        data = result
                    else:
                        data = (<AddrInfo>result).unpack()
                except Exception as ex:
                    fut.set_exception(ex)
                else:
                    fut.set_result(data)
            else:
                fut.set_exception(result)

        getaddrinfo(self, host, port, family, type, proto, flags, callback)
        return fut

    @aio_coroutine # XXX
    async def create_server(self, protocol_factory, str host, int port):
        addrinfo = await self._getaddrinfo(host, port, 0, 0, 0, 0, 0)
        if not AddrInfo.isinstance(addrinfo):
            raise RuntimeError('unvalid loop._getaddeinfo() result')

        cdef uv.addrinfo *ai = (<AddrInfo>addrinfo).data
        if ai is NULL:
            raise RuntimeError('loop._getaddeinfo() result is NULL')

        cdef UVTCPServer srv = UVTCPServer(self)
        srv.set_protocol_factory(protocol_factory)

        srv.bind(ai.ai_addr)
        srv.listen()

        self._track_handle(srv)
        return srv

    def call_exception_handler(self, context):
        message = context.get('message')
        if not message:
            message = 'Unhandled exception in event loop'

        exception = context.get('exception')
        if exception is not None:
            exc_info = (type(exception), exception, exception.__traceback__)
        else:
            exc_info = False

        aio_logger.error(message, exc_info=exc_info)


@cython.internal
@cython.freelist(100)
cdef class Handle:
    cdef:
        object callback
        int cancelled
        int done
        object __weakref__

    def __cinit__(self, Loop loop, object callback):
        self.callback = callback
        self.cancelled = 0
        self.done = 0

    cdef _run(self):
        if self.cancelled == 0 and self.done == 0:
            self.done = 1
            self.callback()

    # Public API

    cpdef cancel(self):
        self.cancelled = 1
        self.callback = None


@cython.internal
@cython.freelist(100)
cdef class TimerHandle:
    cdef:
        object callback
        int cancelled
        int closed
        UVTimer timer
        Loop loop
        object __weakref__

    def __cinit__(self, Loop loop, object callback, uint64_t delay):
        self.loop = loop
        self.callback = callback
        self.cancelled = 0
        self.closed = 0

        self.timer = UVTimer(loop, self._run, delay, self._remove_self)
        self.timer.start()

        loop._timers.add(self)

    def __del__(self):
        self.close()

    def _remove_self(self):
        try:
            self.loop._timers.remove(self)
        except KeyError:
            pass
        finally:
            self.timer = None
            self.loop = None
            self.callback = None

    cdef close(self):
        if self.closed == 0:
            self.closed = 1
            self.timer.close()

    def _run(self):
        if self.cancelled == 0 and self.closed == 0:
            self.close()
            self.callback()

    # Public API

    cpdef cancel(self):
        if self.cancelled == 0:
            self.cancelled = 1
            self.callback = None
            self.close()


include "handle.pyx"
include "async_.pyx"
include "idle.pyx"
include "timer.pyx"
include "signal.pyx"

include "stream.pyx"
include "tcp.pyx"

include "dns.pyx"
include "server.pyx"
