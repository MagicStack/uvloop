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


include "consts.pxi"
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
        cdef int err

        self.loop = <uv.uv_loop_t*> \
                            PyMem_Malloc(sizeof(uv.uv_loop_t))
        if self.loop is NULL:
            raise MemoryError()

        self.loop.data = <void*> self
        self._closed = 0
        self._debug = 0
        self._thread_id = 0
        self._running = 0
        self._stopping = 0

        self._handles = set()
        self._polls = dict()
        self._polls_gc = dict()

        self._recv_buffer_in_use = 0

        err = uv.uv_loop_init(self.loop)
        if err < 0:
            raise UVError.from_error(err)

        self._last_error = None

        self._task_factory = None
        self._exception_handler = None
        self._default_executor = None

        self._ready = col_deque()
        self._ready_len = 0

        self.handler_async = UVAsync(self, self._on_wake)
        self.handler_idle = UVIdle(self, self._on_idle)
        self.handler_sigint = UVSignal(self, self._on_sigint, uv.SIGINT)
        self.handler_sighup = UVSignal(self, self._on_sighup, uv.SIGHUP)

    def __del__(self):
        self._close()

    def __dealloc__(self):
        try:
            if self._closed == 0:
                aio_logger.error("deallocating an active libuv loop")
        finally:
            PyMem_Free(self.loop)
            self.loop = NULL

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
        cdef:
            int i, ntodo
            object popleft = self._ready.popleft
            Handle handler

        ntodo = len(self._ready)
        for i from 0 <= i < ntodo:
            handler = <Handle> popleft()
            if handler.cancelled == 0:
                try:
                    handler._run()
                except BaseException as ex:
                    self._stop(ex)
                    return

        if len(self._polls_gc):
            for fd in tuple(self._polls_gc):
                poll = <UVPoll> self._polls_gc[fd]
                if not poll.is_active():
                    poll.close()
                    self._polls.pop(fd)
                self._polls_gc.pop(fd)

        self._ready_len = len(self._ready)
        if self._ready_len == 0 and self.handler_idle.running:
            self.handler_idle.stop()

    cdef _stop(self, exc=None):
        if exc is not None:
            self._last_error = exc
        if self._stopping == 1:
            return
        self._stopping = 1
        uv.uv_stop(self.loop)

    cdef inline void __track_handle__(self, UVHandle handle):
        """Internal helper for tracking UVHandles. Do not use."""
        self._handles.add(handle)

    cdef inline void __untrack_handle__(self, UVHandle handle):
        """Internal helper for tracking UVHandles. Do not use."""
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
        self._stopping = 0

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
        self._stopping = 0

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

        self._ready.clear()
        self._ready_len = 0

        if self._handles:
            self._polls.clear()
            self._polls_gc.clear()

            for handle in tuple(self._handles):
                (<UVHandle>handle).close()

        # Allow loop to fire "close" callbacks
        with nogil:
            err = uv.uv_run(self.loop, uv.UV_RUN_DEFAULT)

        if err < 0:
            raise UVError.from_error(err)

        err = uv.uv_loop_close(self.loop)
        if err < 0:
            raise UVError.from_error(err)

        if self._handles:
            raise RuntimeError(
                "new handles were queued during loop closing: {}"
                    .format(self._handles))

        if self._ready:
            raise RuntimeError(
                "new callbacks were queued during loop closing: {}"
                    .format(self._ready))

        executor = self._default_executor
        if executor is not None:
            self._default_executor = None
            executor.shutdown(wait=False)

    cdef uint64_t _time(self):
        return uv.uv_now(self.loop)

    cdef _call_soon(self, object callback, object args):
        self._check_closed()
        handle = Handle(self, callback, args)
        self._ready.append(handle)
        self._ready_len += 1;
        if not self.handler_idle.running:
            self.handler_idle.start()
        return handle

    cdef _call_later(self, uint64_t delay, object callback, object args):
        return TimerHandle(self, callback, args, delay)

    cdef void _handle_uvcb_exception(self, object ex):
        if isinstance(ex, Exception):
            self.call_exception_handler({'exception': ex})
        else:
            # BaseException
            self._last_error = ex
            # Exit ASAP
            self._stop()

    cdef inline _check_closed(self):
        if self._closed == 1:
            raise RuntimeError('Event loop is closed')

    cdef inline _check_thread(self):
        if self._thread_id == 0:
            return
        cdef long thread_id = PyThread_get_thread_ident()
        if thread_id != self._thread_id:
            raise RuntimeError(
                "Non-thread-safe operation invoked on an event loop other "
                "than the current one")

    cdef _getaddrinfo(self, str host, int port,
                      int family, int type,
                      int proto, int flags,
                      int unpack):

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

    def _sock_recv(self, fut, registered, sock, n):
        # _sock_recv() can add itself as an I/O callback if the operation can't
        # be done immediately. Don't use it directly, call sock_recv().
        fd = sock.fileno()
        if registered:
            # Remove the callback early.  It should be rare that the
            # selector says the fd is ready but the call still returns
            # EAGAIN, and I am willing to take a hit in that case in
            # order to simplify the common case.
            self.remove_reader(fd)
        if fut.cancelled():
            return
        try:
            data = sock.recv(n)
        except (BlockingIOError, InterruptedError):
            self.add_reader(fd, self._sock_recv, fut, True, sock, n)
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(data)

    def _sock_sendall(self, fut, registered, sock, data):
        fd = sock.fileno()

        if registered:
            self.remove_writer(fd)
        if fut.cancelled():
            return

        try:
            n = sock.send(data)
        except (BlockingIOError, InterruptedError):
            n = 0
        except Exception as exc:
            fut.set_exception(exc)
            return

        if n == len(data):
            fut.set_result(None)
        else:
            if n:
                data = data[n:]
            self.add_writer(fd, self._sock_sendall, fut, True, sock, data)

    def _sock_accept(self, fut, registered, sock):
        fd = sock.fileno()
        if registered:
            self.remove_reader(fd)
        if fut.cancelled():
            return
        try:
            conn, address = sock.accept()
            conn.setblocking(False)
        except (BlockingIOError, InterruptedError):
            self.add_reader(fd, self._sock_accept, fut, True, sock)
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result((conn, address))

    def _sock_connect(self, fut, sock, address):
        fd = sock.fileno()
        try:
            sock.connect(address)
        except (BlockingIOError, InterruptedError):
            # Issue #23618: When the C function connect() fails with EINTR, the
            # connection runs in background. We have to wait until the socket
            # becomes writable to be notified when the connection succeed or
            # fails.
            fut.add_done_callback(ft_partial(self._sock_connect_done, fd))
            self.add_writer(fd, self._sock_connect_cb, fut, sock, address)
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(None)

    def _sock_connect_done(self, fd, fut):
        self.remove_writer(fd)

    def _sock_connect_cb(self, fut, sock, address):
        if fut.cancelled():
            return

        try:
            err = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            if err != 0:
                # Jump to any except clause below.
                raise OSError(err, 'Connect call failed %s' % (address,))
        except (BlockingIOError, InterruptedError):
            # socket is still registered, the callback will be retried later
            pass
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(None)

    # Public API

    def __repr__(self):
        return ('<%s running=%s closed=%s debug=%s>'
                % (self.__class__.__name__, self.is_running(),
                   self.is_closed(), self.get_debug()))

    def call_soon(self, callback, *args):
        if self._debug == 1:
            self._check_thread()
        if not args:
            args = None
        return self._call_soon(callback, args)

    def call_soon_threadsafe(self, callback, *args):
        if not args:
            args = None
        handle = self._call_soon(callback, args)
        self.handler_async.send()
        return handle

    def call_later(self, delay, callback, *args):
        self._check_closed()
        if self._debug == 1:
            self._check_thread()
        if delay < 0:
            delay = 0
        cdef uint64_t when = <uint64_t>(delay * 1000)
        if not args:
            args = None
        if when == 0:
            return self._call_soon(callback, args)
        else:
            return self._call_later(when, callback, args)

    def call_at(self, when, callback, *args):
        return self.call_later(when - self.time(), callback, *args)

    def time(self):
        return self._time() / 1000

    def stop(self):
        self._call_soon(lambda: self._stop(), None)

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
        if self._task_factory is None:
            task = aio_Task(coro, loop=self)
            if task._source_traceback:
                del task._source_traceback[-1]
        else:
            task = self._task_factory(self, coro)
        return task

    def set_task_factory(self, factory):
        if factory is not None and not callable(factory):
            raise TypeError('task factory must be a callable or None')
        self._task_factory = factory

    def get_task_factory(self):
        return self._task_factory

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

    @aio_coroutine
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
        return srv

    def default_exception_handler(self, context):
        message = context.get('message')
        if not message:
            message = 'Unhandled exception in event loop'

        exception = context.get('exception')
        if exception is not None:
            exc_info = (type(exception), exception, exception.__traceback__)
        else:
            exc_info = False

        aio_logger.error(message, exc_info=exc_info)

    def set_exception_handler(self, handler):
        if handler is not None and not callable(handler):
            raise TypeError('A callable object or None is expected, '
                            'got {!r}'.format(handler))
        self._exception_handler = handler

    def call_exception_handler(self, context):
        if self._exception_handler is None:
            try:
                self.default_exception_handler(context)
            except Exception:
                # Second protection layer for unexpected errors
                # in the default implementation, as well as for subclassed
                # event loops with overloaded "default_exception_handler".
                aio_logger.error('Exception in default exception handler',
                                 exc_info=True)
        else:
            try:
                self._exception_handler(self, context)
            except Exception as exc:
                # Exception in the user set custom exception handler.
                try:
                    # Let's try default handler.
                    self.default_exception_handler({
                        'message': 'Unhandled error in exception handler',
                        'exception': exc,
                        'context': context,
                    })
                except Exception:
                    # Guard 'default_exception_handler' in case it is
                    # overloaded.
                    aio_logger.error('Exception in default exception handler '
                                     'while handling an unexpected error '
                                     'in custom exception handler',
                                     exc_info=True)

    def add_reader(self, fd, callback, *args):
        cdef:
            UVPoll poll

        self._check_closed()

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            poll = UVPoll(self, fd)
            self._polls[fd] = poll

        if not args:
            args = None

        poll.start_reading(Handle(self, callback, args))

    def remove_reader(self, fd):
        cdef:
            UVPoll poll

        if self._closed == 1:
            return False

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            return False

        result = poll.stop_reading()
        if not poll.is_active():
            self._polls_gc[fd] = poll
        return result

    def add_writer(self, fd, callback, *args):
        cdef:
            UVPoll poll

        self._check_closed()

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            poll = UVPoll(self, fd)
            self._polls[fd] = poll

        if not args:
            args = None

        poll.start_writing(Handle(self, callback, args))

    def remove_writer(self, fd):
        cdef:
            UVPoll poll

        if self._closed == 1:
            return False

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            return False

        result = poll.stop_writing()
        if not poll.is_active():
            self._polls_gc[fd] = poll
        return result

    def sock_recv(self, sock, n):
        fut = aio_Future(loop=self)
        self._sock_recv(fut, False, sock, n)
        return fut

    def sock_sendall(self, sock, data):
        fut = aio_Future(loop=self)
        if data:
            self._sock_sendall(fut, False, sock, data)
        else:
            fut.set_result(None)
        return fut

    def sock_accept(self, sock):
        fut = aio_Future(loop=self)
        self._sock_accept(fut, False, sock)
        return fut

    def sock_connect(self, sock, address):
        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")
        fut = aio_Future(loop=self)
        try:
            if self._debug:
                aio__check_resolved_address(sock, address)
        except ValueError as err:
            fut.set_exception(err)
        else:
            self._sock_connect(fut, sock, address)
        return fut

    def run_in_executor(self, executor, func, *args):
        if aio_iscoroutine(func) or aio_iscoroutinefunction(func):
            raise TypeError("coroutines cannot be used with run_in_executor()")

        self._check_closed()

        if executor is None:
            executor = self._default_executor
            if executor is None:
                executor = cc_ThreadPoolExecutor(MAX_THREADPOOL_WORKERS)
                self._default_executor = executor

        return aio_wrap_future(executor.submit(func, *args), loop=self)

    def set_default_executor(self, executor):
        self._default_executor = executor


include "cbhandles.pyx"

include "handle.pyx"
include "async_.pyx"
include "idle.pyx"
include "timer.pyx"
include "signal.pyx"
include "poll.pyx"

include "stream.pyx"
include "tcp.pyx"

include "dns.pyx"
include "server.pyx"
