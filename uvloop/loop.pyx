# cython: language_level=3, embedsignature=True

import asyncio
cimport cython

from .includes.debug cimport UVLOOP_DEBUG
from .includes cimport uv
from .includes cimport system
from .includes.python cimport PyMem_RawMalloc, PyMem_RawFree, \
                              PyMem_RawCalloc, PyMem_RawRealloc, \
                              PyUnicode_EncodeFSDefault, \
                              PyErr_SetInterrupt, \
                              PyOS_AfterFork, \
                              _PyImport_AcquireLock, \
                              _PyImport_ReleaseLock, \
                              _Py_RestoreSignals

from libc.stdint cimport uint64_t
from libc.string cimport memset, strerror, memcpy
from libc cimport errno

from cpython cimport PyObject
from cpython cimport PyErr_CheckSignals, PyErr_Occurred
from cpython cimport PyThread_get_thread_ident
from cpython cimport Py_INCREF, Py_DECREF, Py_XDECREF, Py_XINCREF
from cpython cimport PyObject_GetBuffer, PyBuffer_Release, PyBUF_SIMPLE, \
                     Py_buffer, PyBytes_AsString, PyBytes_CheckExact, \
                     Py_SIZE, PyBytes_AS_STRING

from cpython cimport PyErr_CheckSignals

from . import _noop


include "includes/consts.pxi"
include "includes/stdlib.pxi"

include "errors.pyx"


cdef _is_sock_stream(sock_type):
    # Linux's socket.type is a bitmask that can include extra info
    # about socket, therefore we can't do simple
    # `sock_type == socket.SOCK_STREAM`.
    return (sock_type & uv.SOCK_STREAM) == uv.SOCK_STREAM


cdef _is_sock_dgram(sock_type):
    # Linux's socket.type is a bitmask that can include extra info
    # about socket, therefore we can't do simple
    # `sock_type == socket.SOCK_DGRAM`.
    return (sock_type & uv.SOCK_DGRAM) == uv.SOCK_DGRAM


cdef isfuture(obj):
    if aio_isfuture is None:
        return isinstance(obj, aio_Future)
    else:
        return aio_isfuture(obj)

cdef inline int _as_fd(obj):
    """Return an integer FD from an FD or an object with a .fileno() method"""
    if isinstance(obj, int):
        return obj
    elif hasattr(obj, 'fileno'):
        return obj.fileno()
    else:
        raise TypeError("%r is not an integer fd and has no .fileno() method" % obj)

@cython.no_gc_clear
cdef class Loop:
    def __cinit__(self):
        cdef int err

        # Install PyMem* memory allocators if they aren't installed yet.
        __install_pymem()

        # Install pthread_atfork handlers
        __install_atfork()

        self.uvloop = <uv.uv_loop_t*> \
                            PyMem_RawMalloc(sizeof(uv.uv_loop_t))
        if self.uvloop is NULL:
            raise MemoryError()

        self.slow_callback_duration = 0.1

        self._closed = 0
        self._debug = 0
        self._thread_is_main = 0
        self._thread_id = 0
        self._running = 0
        self._stopping = 0

        self._transports = weakref_WeakValueDictionary()

        self._timers = set()
        self._polls = dict()

        self._recv_buffer_in_use = 0

        err = uv.uv_loop_init(self.uvloop)
        if err < 0:
            raise convert_error(err)
        self.uvloop.data = <void*> self

        self._init_debug_fields()

        self.active_process_handler = None

        self._last_error = None

        self._task_factory = None
        self._exception_handler = None
        self._default_executor = None

        self._queued_streams = set()
        self._ready = col_deque()
        self._ready_len = 0

        self.handler_async = UVAsync.new(
            self, <method_t>self._on_wake, self)

        self.handler_idle = UVIdle.new(
            self,
            new_MethodHandle(
                self, "loop._on_idle", <method_t>self._on_idle, self))

        # Needed to call `UVStream._exec_write` for writes scheduled
        # during `Protocol.data_received`.
        self.handler_check__exec_writes = UVCheck.new(
            self,
            new_MethodHandle(
                self, "loop._exec_queued_writes",
                <method_t>self._exec_queued_writes, self))

        self._ssock = self._csock = None
        self._signal_handlers = None

        self._coroutine_wrapper_set = False

        if hasattr(sys, 'get_asyncgen_hooks'):
            # Python >= 3.6
            # A weak set of all asynchronous generators that are
            # being iterated by the loop.
            self._asyncgens = weakref_WeakSet()
        else:
            self._asyncgens = None

        # Set to True when `loop.shutdown_asyncgens` is called.
        self._asyncgens_shutdown_called = False

    def __init__(self):
        self.set_debug((not sys_ignore_environment
                        and bool(os_environ.get('PYTHONASYNCIODEBUG'))))

    def __dealloc__(self):
        if self._running == 1:
            raise RuntimeError('deallocating a running event loop!')
        if self._closed == 0:
            aio_logger.error("deallocating an open event loop")
            return
        PyMem_RawFree(self.uvloop)
        self.uvloop = NULL

    cdef _init_debug_fields(self):
        self._debug_cc = bool(UVLOOP_DEBUG)

        if UVLOOP_DEBUG:
            self._debug_handles_current = col_Counter()
            self._debug_handles_closed = col_Counter()
            self._debug_handles_total = col_Counter()
        else:
            self._debug_handles_current = None
            self._debug_handles_closed = None
            self._debug_handles_total = None

        self._debug_uv_handles_total = 0
        self._debug_uv_handles_freed = 0

        self._debug_stream_read_cb_total = 0
        self._debug_stream_read_eof_total = 0
        self._debug_stream_read_errors_total = 0
        self._debug_stream_read_cb_errors_total = 0
        self._debug_stream_read_eof_cb_errors_total = 0

        self._debug_stream_shutdown_errors_total = 0
        self._debug_stream_listen_errors_total = 0

        self._debug_stream_write_tries = 0
        self._debug_stream_write_errors_total = 0
        self._debug_stream_write_ctx_total = 0
        self._debug_stream_write_ctx_cnt = 0
        self._debug_stream_write_cb_errors_total = 0

        self._debug_cb_handles_total = 0
        self._debug_cb_handles_count = 0

        self._debug_cb_timer_handles_total = 0
        self._debug_cb_timer_handles_count = 0

        self._poll_read_events_total = 0
        self._poll_read_cb_errors_total = 0
        self._poll_write_events_total = 0
        self._poll_write_cb_errors_total = 0

        self._sock_try_write_total = 0

        self._debug_exception_handler_cnt = 0

    cdef _setup_signals(self):
        self._ssock, self._csock = socket_socketpair()
        self._ssock.setblocking(False)
        self._csock.setblocking(False)
        try:
            signal_set_wakeup_fd(self._csock.fileno())
        except ValueError:
            # Not the main thread
            self._ssock.close()
            self._csock.close()
            self._ssock = self._csock = None
            return

        self._add_reader(
            self._ssock.fileno(),
            new_MethodHandle(
                self,
                "Loop._read_from_self",
                <method_t>self._read_from_self,
                self))

        self._signal_handlers = {}

    cdef _shutdown_signals(self):
        if self._signal_handlers is None:
            return
        for sig in list(self._signal_handlers):
            self.remove_signal_handler(sig)
        signal_set_wakeup_fd(-1)
        self._remove_reader(self._ssock.fileno())
        self._ssock.close()
        self._csock.close()

    cdef _read_from_self(self):
        while True:
            try:
                data = self._ssock.recv(4096)
                if not data:
                    break
                self._process_self_data(data)
            except InterruptedError:
                continue
            except BlockingIOError:
                break

    cdef _process_self_data(self, data):
        for signum in data:
            if not signum:
                # ignore null bytes written by _write_to_self()
                continue
            self._handle_signal(signum)

    cdef _handle_signal(self, sig):
        cdef Handle handle

        try:
            handle = <Handle>(self._signal_handlers[sig])
        except KeyError:
            handle = None

        if handle is None:
            # Some signal that we aren't listening through
            # add_signal_handler.  Invoke CPython eval loop
            # to let it being processed.
            PyErr_CheckSignals()
            _noop.noop()
            return

        if handle.cancelled:
            self.remove_signal_handler(sig)  # Remove it properly.
        else:
            self._call_soon_handle(handle)
            self.handler_async.send()

    cdef _on_wake(self):
        if (self._ready_len > 0 or self._stopping) \
                            and not self.handler_idle.running:
            self.handler_idle.start()

    cdef _on_idle(self):
        cdef:
            int i, ntodo
            object popleft = self._ready.popleft
            Handle handler

        ntodo = len(self._ready)
        if self._debug:
            for i from 0 <= i < ntodo:
                handler = <Handle> popleft()
                if handler.cancelled == 0:
                    try:
                        started = time_monotonic()
                        handler._run()
                    except BaseException as ex:
                        self._stop(ex)
                        return
                    else:
                        delta = time_monotonic() - started
                        if delta > self.slow_callback_duration:
                            aio_logger.warning(
                                'Executing %r took %.3f seconds',
                                handler, delta)

        else:
            for i from 0 <= i < ntodo:
                handler = <Handle> popleft()
                if handler.cancelled == 0:
                    try:
                        handler._run()
                    except BaseException as ex:
                        self._stop(ex)
                        return

        if len(self._queued_streams):
            self._exec_queued_writes()

        self._ready_len = len(self._ready)
        if self._ready_len == 0 and self.handler_idle.running:
            self.handler_idle.stop()

        if self._stopping:
            uv.uv_stop(self.uvloop)  # void

    cdef _stop(self, exc):
        if exc is not None:
            self._last_error = exc
        if self._stopping == 1:
            return
        self._stopping = 1
        if not self.handler_idle.running:
            self.handler_idle.start()

    cdef __run(self, uv.uv_run_mode mode):
        # Although every UVHandle holds a reference to the loop,
        # we want to do everything to ensure that the loop will
        # never deallocate during the run -- so we do some
        # manual refs management.
        Py_INCREF(self)
        with nogil:
            err = uv.uv_run(self.uvloop, mode)
        Py_DECREF(self)

        if err < 0:
            raise convert_error(err)

    cdef _run(self, uv.uv_run_mode mode):
        cdef int err

        if self._closed == 1:
            raise RuntimeError('unable to start the loop; it was closed')

        if self._running == 1:
            raise RuntimeError('this event loop is already running.')

        if (aio_get_running_loop is not None and
                aio_get_running_loop() is not None):
            raise RuntimeError(
                'Cannot run the event loop while another loop is running')

        if self._signal_handlers is None:
            self._setup_signals()

        # reset _last_error
        self._last_error = None

        self._thread_id = PyThread_get_thread_ident()
        self._thread_is_main = MAIN_THREAD_ID == self._thread_id
        self._running = 1

        self.handler_check__exec_writes.start()
        self.handler_idle.start()

        if aio_set_running_loop is not None:
            aio_set_running_loop(self)
        try:
            self.__run(mode)
        finally:
            if aio_set_running_loop is not None:
                aio_set_running_loop(None)

        self.handler_check__exec_writes.stop()
        self.handler_idle.stop()

        self._thread_is_main = 0
        self._thread_id = 0
        self._running = 0
        self._stopping = 0

        if self._last_error is not None:
            # The loop was stopped with an error with 'loop._stop(error)' call
            raise self._last_error

    cdef _close(self):
        cdef int err

        if self._running == 1:
            raise RuntimeError("Cannot close a running event loop")

        if self._closed == 1:
            return

        self._closed = 1

        for cb_handle in self._ready:
            cb_handle.cancel()
        self._ready.clear()
        self._ready_len = 0

        if self._polls:
            for poll_handle in self._polls.values():
                (<UVHandle>poll_handle)._close()

            self._polls.clear()

        if self._timers:
            for timer_cbhandle in tuple(self._timers):
                timer_cbhandle.cancel()

        # Close all remaining handles
        self.handler_async._close()
        self.handler_idle._close()
        self.handler_check__exec_writes._close()
        __close_all_handles(self)
        self._shutdown_signals()
        # During this run there should be no open handles,
        # so it should finish right away
        self.__run(uv.UV_RUN_DEFAULT)

        if self._timers:
            raise RuntimeError(
                "new timers were queued during loop closing: {}"
                    .format(self._timers))

        if self._polls:
            raise RuntimeError(
                "new poll handles were queued during loop closing: {}"
                    .format(self._polls))

        if self._ready:
            raise RuntimeError(
                "new callbacks were queued during loop closing: {}"
                    .format(self._ready))

        err = uv.uv_loop_close(self.uvloop)
        if err < 0:
            raise convert_error(err)

        self.handler_async = None
        self.handler_idle = None
        self.handler_check__exec_writes = None

        executor = self._default_executor
        if executor is not None:
            self._default_executor = None
            executor.shutdown(wait=False)

    cdef uint64_t _time(self):
        # asyncio doesn't have a time cache, neither should uvloop.
        uv.uv_update_time(self.uvloop)  # void
        return uv.uv_now(self.uvloop)

    cdef inline _queue_write(self, UVStream stream):
        self._queued_streams.add(stream)
        if not self.handler_check__exec_writes.running:
            self.handler_check__exec_writes.start()

    cdef _exec_queued_writes(self):
        if len(self._queued_streams) == 0:
            if self.handler_check__exec_writes.running:
                self.handler_check__exec_writes.stop()
            return

        cdef:
            UVStream stream
            int queued_len

        if UVLOOP_DEBUG:
            queued_len = len(self._queued_streams)

        for pystream in self._queued_streams:
            stream = <UVStream>pystream
            stream._exec_write()

        if UVLOOP_DEBUG:
            if len(self._queued_streams) != queued_len:
                raise RuntimeError(
                    'loop._queued_streams are not empty after '
                    '_exec_queued_writes')

        self._queued_streams.clear()

        if self.handler_check__exec_writes.running:
            self.handler_check__exec_writes.stop()

    cdef inline _call_soon(self, object callback, object args):
        cdef Handle handle
        handle = new_Handle(self, callback, args)
        self._call_soon_handle(handle)
        return handle

    cdef inline _call_soon_handle(self, Handle handle):
        self._check_closed()
        self._ready.append(handle)
        self._ready_len += 1;
        if not self.handler_idle.running:
            self.handler_idle.start()

    cdef _call_later(self, uint64_t delay, object callback, object args):
        return TimerHandle(self, callback, args, delay)

    cdef void _handle_exception(self, object ex):
        if isinstance(ex, Exception):
            self.call_exception_handler({'exception': ex})
        else:
            # BaseException
            self._last_error = ex
            # Exit ASAP
            self._stop(None)

    cdef inline _check_signal(self, sig):
        if not isinstance(sig, int):
            raise TypeError('sig must be an int, not {!r}'.format(sig))

        if not (1 <= sig < signal_NSIG):
            raise ValueError(
                'sig {} out of range(1, {})'.format(sig, signal_NSIG))

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

    cdef inline _new_future(self):
        return future_factory(loop=self)

    cdef _track_transport(self, UVBaseTransport transport):
        self._transports[transport._fileno()] = transport

    cdef _ensure_fd_no_transport(self, fd):
        cdef UVBaseTransport tr
        try:
            tr = <UVBaseTransport>(self._transports[fd])
        except KeyError:
            pass
        else:
            if tr._is_alive():
                raise RuntimeError(
                    'File descriptor {!r} is used by transport {!r}'.format(
                        fd, tr))

    cdef inline _add_reader(self, fd, Handle handle):
        cdef:
            UVPoll poll

        self._check_closed()

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            poll = UVPoll.new(self, fd)
            self._polls[fd] = poll

        poll.start_reading(handle)

    cdef inline _remove_reader(self, fd):
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
            del self._polls[fd]
            poll._close()
        return result

    cdef inline _add_writer(self, fd, Handle handle):
        cdef:
            UVPoll poll

        self._check_closed()

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            poll = UVPoll.new(self, fd)
            self._polls[fd] = poll

        poll.start_writing(handle)

    cdef inline _remove_writer(self, fd):
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
            del self._polls[fd]
            poll._close()
        return result

    cdef _getaddrinfo(self, object host, object port,
                      int family, int type,
                      int proto, int flags,
                      int unpack):

        if isinstance(port, str):
            port = port.encode()
        elif isinstance(port, int):
            port = str(port).encode()
        if port is not None and not isinstance(port, bytes):
            raise TypeError('port must be a str, bytes or int')

        if isinstance(host, str):
            host = host.encode('idna')
        if host is not None:
            if not isinstance(host, bytes):
                raise TypeError('host must be a str or bytes')

        fut = self._new_future()

        def callback(result):
            if AddrInfo.isinstance(result):
                try:
                    if unpack == 0:
                        data = result
                    else:
                        data = (<AddrInfo>result).unpack()
                except Exception as ex:
                    if not fut.cancelled():
                        fut.set_exception(ex)
                else:
                    if not fut.cancelled():
                        fut.set_result(data)
            else:
                if not fut.cancelled():
                    fut.set_exception(result)

        AddrInfoRequest(self, host, port, family, type, proto, flags, callback)
        return fut

    cdef _getnameinfo(self, system.sockaddr *addr, int flags):
        cdef NameInfoRequest nr
        fut = self._new_future()

        def callback(result):
            if isinstance(result, tuple):
                fut.set_result(result)
            else:
                fut.set_exception(result)

        nr = NameInfoRequest(self, callback)
        nr.query(addr, flags)
        return fut

    cdef _sock_recv(self, fut, sock, n):
        cdef:
            Handle handle
            int fd

        fd = sock.fileno()
        if fut.cancelled():
            self._remove_reader(fd)
            return

        try:
            data = sock.recv(n)
        except (BlockingIOError, InterruptedError):
            # No need to re-add the reader, let's just wait until
            # the poll handler calls this callback again.
            pass
        except Exception as exc:
            fut.set_exception(exc)
            self._remove_reader(fd)
        else:
            fut.set_result(data)
            self._remove_reader(fd)

    cdef _sock_sendall(self, fut, sock, data):
        cdef:
            Handle handle
            int n
            int fd

        fd = sock.fileno()

        if fut.cancelled():
            self._remove_writer(fd)
            return

        try:
            n = sock.send(data)
        except (BlockingIOError, InterruptedError):
            # Try next time.
            return
        except Exception as exc:
            fut.set_exception(exc)
            self._remove_writer(fd)
            return

        if n == len(data):
            fut.set_result(None)
            self._remove_writer(fd)
        else:
            if n:
                if not isinstance(data, memoryview):
                    data = memoryview(data)
                data = data[n:]

            handle = new_MethodHandle3(
                self,
                "Loop._sock_sendall",
                <method3_t>self._sock_sendall,
                self,
                fut, sock, data)

            self._add_writer(fd, handle)

    cdef _sock_accept(self, fut, sock):
        cdef:
            Handle handle

        fd = sock.fileno()

        if fut.cancelled():
            self._remove_reader(fd)
            return

        try:
            conn, address = sock.accept()
            conn.setblocking(False)
        except (BlockingIOError, InterruptedError):
            # There is an active reader for _sock_accept, so
            # do nothing, it will be called again.
            pass
        except Exception as exc:
            fut.set_exception(exc)
            self._remove_reader(fd)
        else:
            fut.set_result((conn, address))
            self._remove_reader(fd)

    cdef _sock_connect(self, fut, sock, address):
        cdef:
            Handle handle

        fd = sock.fileno()
        try:
            sock.connect(address)
        except (BlockingIOError, InterruptedError):
            # Issue #23618: When the C function connect() fails with EINTR, the
            # connection runs in background. We have to wait until the socket
            # becomes writable to be notified when the connection succeed or
            # fails.
            fut.add_done_callback(lambda fut: self._remove_writer(fd))

            handle = new_MethodHandle3(
                self,
                "Loop._sock_connect",
                <method3_t>self._sock_connect_cb,
                self,
                fut, sock, address)

            self._add_writer(fd, handle)
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(None)

    cdef _sock_connect_cb(self, fut, sock, address):
        if fut.cancelled():
            return

        try:
            err = sock.getsockopt(uv.SOL_SOCKET, uv.SO_ERROR)
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

    cdef _sock_set_reuseport(self, int fd):
        cdef:
            int err
            int reuseport_flag = 1

        err = system.setsockopt(
            fd,
            uv.SOL_SOCKET,
            SO_REUSEPORT,
            <char*>&reuseport_flag,
            sizeof(reuseport_flag))

        if err < 0:
            raise convert_error(-errno.errno)

    cdef _set_coroutine_wrapper(self, bint enabled):
        enabled = bool(enabled)
        if self._coroutine_wrapper_set == enabled:
            return

        wrapper = aio_debug_wrapper
        current_wrapper = sys_get_coroutine_wrapper()

        if enabled:
            if current_wrapper not in (None, wrapper):
                warnings.warn(
                    "loop.set_debug(True): cannot set debug coroutine "
                    "wrapper; another wrapper is already set %r" %
                    current_wrapper, RuntimeWarning)
            else:
                sys_set_coroutine_wrapper(wrapper)
                self._coroutine_wrapper_set = True
        else:
            if current_wrapper not in (None, wrapper):
                warnings.warn(
                    "loop.set_debug(False): cannot unset debug coroutine "
                    "wrapper; another wrapper was set %r" %
                    current_wrapper, RuntimeWarning)
            else:
                sys_set_coroutine_wrapper(None)
                self._coroutine_wrapper_set = False

    cdef _create_server(self, system.sockaddr *addr,
                        object protocol_factory,
                        Server server,
                        object ssl,
                        bint reuse_port,
                        object backlog):
        cdef:
            TCPServer tcp
            int bind_flags

        tcp = TCPServer.new(self, protocol_factory, server, ssl,
                            addr.sa_family)

        if reuse_port:
            self._sock_set_reuseport(tcp._fileno())

        if addr.sa_family == uv.AF_INET6:
            # Disable IPv4/IPv6 dual stack support (enabled by
            # default on Linux) which makes a single socket
            # listen on both address families.
            bind_flags = uv.UV_TCP_IPV6ONLY
        else:
            bind_flags = 0

        try:
            tcp.bind(addr, bind_flags)
            tcp.listen(backlog)
        except OSError as err:
            pyaddr = __convert_sockaddr_to_pyaddr(addr)
            tcp._close()
            raise OSError(err.errno, 'error while attempting '
                          'to bind on address %r: %s'
                          % (pyaddr, err.strerror.lower()))
        except:
            tcp._close()
            raise

        return tcp

    def _get_backend_id(self):
        """This method is used by uvloop tests and is not part of the API."""
        return uv.uv_backend_fd(self.uvloop)

    def print_debug_info(self):
        cdef:
            int err
            uv.uv_rusage_t rusage

        if not UVLOOP_DEBUG:
            raise NotImplementedError

        err = uv.uv_getrusage(&rusage)
        if err < 0:
            raise convert_error(err)

        ################### OS

        print('---- Process info: -----')
        print('Process memory:            {}'.format(rusage.ru_maxrss))
        print('Number of signals:         {}'.format(rusage.ru_nsignals))
        print('')

        ################### Loop

        print('--- Loop debug info: ---')
        print('Loop time:                 {}'.format(self.time()))
        print('Errors logged:             {}'.format(
            self._debug_exception_handler_cnt))
        print()
        print('Callback handles:          {: <8} | {}'.format(
            self._debug_cb_handles_count,
            self._debug_cb_handles_total))
        print('Timer handles:             {: <8} | {}'.format(
            self._debug_cb_timer_handles_count,
            self._debug_cb_timer_handles_total))
        print()

        print('                        alive  | closed  |')
        print('UVHandles               python | libuv   | total')
        print('                        objs   | handles |')
        print('-------------------------------+---------+---------')
        for name in sorted(self._debug_handles_total):
            print('    {: <18} {: >7} | {: >7} | {: >7}'.format(
                name,
                self._debug_handles_current[name],
                self._debug_handles_closed[name],
                self._debug_handles_total[name]))
        print()

        print('uv_handle_t (current: {}; freed: {}; total: {})'.format(
            self._debug_uv_handles_total - self._debug_uv_handles_freed,
            self._debug_uv_handles_freed,
            self._debug_uv_handles_total))
        print()

        print('--- Streams debug info: ---')
        print('Write errors:              {}'.format(
            self._debug_stream_write_errors_total))
        print('Write without poll:        {}'.format(
            self._debug_stream_write_tries))
        print('Write contexts:            {: <8} | {}'.format(
            self._debug_stream_write_ctx_cnt,
            self._debug_stream_write_ctx_total))
        print('Write failed callbacks:    {}'.format(
            self._debug_stream_write_cb_errors_total))
        print()
        print('Read errors:               {}'.format(
            self._debug_stream_read_errors_total))
        print('Read callbacks:            {}'.format(
            self._debug_stream_read_cb_total))
        print('Read failed callbacks:     {}'.format(
            self._debug_stream_read_cb_errors_total))
        print('Read EOFs:                 {}'.format(
            self._debug_stream_read_eof_total))
        print('Read EOF failed callbacks: {}'.format(
            self._debug_stream_read_eof_cb_errors_total))
        print()
        print('Listen errors:             {}'.format(
            self._debug_stream_listen_errors_total))
        print('Shutdown errors            {}'.format(
            self._debug_stream_shutdown_errors_total))
        print()

        print('--- Polls debug info: ---')
        print('Read events:               {}'.format(
            self._poll_read_events_total))
        print('Read callbacks failed:     {}'.format(
            self._poll_read_cb_errors_total))
        print('Write events:              {}'.format(
            self._poll_write_events_total))
        print('Write callbacks failed:    {}'.format(
            self._poll_write_cb_errors_total))
        print()

        print('--- Sock ops successfull on 1st try: ---')
        print('Socket try-writes:         {}'.format(
            self._sock_try_write_total))

        print(flush=True)

    # Public API

    def __repr__(self):
        return '<{}.{} running={} closed={} debug={}>'.format(
                    self.__class__.__module__,
                    self.__class__.__name__,
                    self.is_running(),
                    self.is_closed(),
                    self.get_debug())

    def call_soon(self, callback, *args):
        """Arrange for a callback to be called as soon as possible.

        This operates as a FIFO queue: callbacks are called in the
        order in which they are registered.  Each callback will be
        called exactly once.

        Any positional arguments after the callback will be passed to
        the callback when it is called.
        """
        if self._debug == 1:
            self._check_thread()
        if args:
            return self._call_soon(callback, args)
        else:
            return self._call_soon(callback, None)

    def call_soon_threadsafe(self, callback, *args):
        """Like call_soon(), but thread-safe."""
        if not args:
            args = None
        handle = self._call_soon(callback, args)
        self.handler_async.send()
        return handle

    def call_later(self, delay, callback, *args):
        """Arrange for a callback to be called at a given time.

        Return a Handle: an opaque object with a cancel() method that
        can be used to cancel the call.

        The delay can be an int or float, expressed in seconds.  It is
        always relative to the current time.

        Each callback will be called exactly once.  If two callbacks
        are scheduled for exactly the same time, it undefined which
        will be called first.

        Any positional arguments after the callback will be passed to
        the callback when it is called.
        """
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
        """Like call_later(), but uses an absolute time.

        Absolute time corresponds to the event loop's time() method.
        """
        return self.call_later(when - self.time(), callback, *args)

    def time(self):
        """Return the time according to the event loop's clock.

        This is a float expressed in seconds since an epoch, but the
        epoch, precision, accuracy and drift are unspecified and may
        differ per event loop.
        """
        return self._time() / 1000

    def stop(self):
        """Stop running the event loop.

        Every callback already scheduled will still run.  This simply informs
        run_forever to stop looping after a complete iteration.
        """
        self._call_soon_handle(
            new_MethodHandle1(
                self,
                "Loop._stop",
                <method1_t>self._stop,
                self,
                None))

    def run_forever(self):
        """Run the event loop until stop() is called."""
        self._check_closed()
        mode = uv.UV_RUN_DEFAULT
        if self._stopping:
            # loop.stop() was called right before loop.run_forever().
            # This is how asyncio loop behaves.
            mode = uv.UV_RUN_NOWAIT
        self._set_coroutine_wrapper(self._debug)
        if self._asyncgens is not None:
            old_agen_hooks = sys.get_asyncgen_hooks()
            sys.set_asyncgen_hooks(firstiter=self._asyncgen_firstiter_hook,
                                   finalizer=self._asyncgen_finalizer_hook)
        try:
            self._run(mode)
        finally:
            self._set_coroutine_wrapper(False)
            if self._asyncgens is not None:
                sys.set_asyncgen_hooks(*old_agen_hooks)

    def close(self):
        """Close the event loop.

        The event loop must not be running.

        This is idempotent and irreversible.

        No other methods should be called after this one.
        """
        self._close()

    def get_debug(self):
        return bool(self._debug)

    def set_debug(self, enabled):
        self._debug = bool(enabled)
        if self.is_running():
            self._set_coroutine_wrapper(self._debug)

    def is_running(self):
        """Return whether the event loop is currently running."""
        return bool(self._running)

    def is_closed(self):
        """Returns True if the event loop was closed."""
        return bool(self._closed)

    def create_future(self):
        """Create a Future object attached to the loop."""
        return self._new_future()

    def create_task(self, coro):
        """Schedule a coroutine object.

        Return a task object.
        """
        self._check_closed()
        if self._task_factory is None:
            task = task_factory(coro, loop=self)
        else:
            task = self._task_factory(self, coro)
        return task

    def set_task_factory(self, factory):
        """Set a task factory that will be used by loop.create_task().

        If factory is None the default task factory will be set.

        If factory is a callable, it should have a signature matching
        '(loop, coro)', where 'loop' will be a reference to the active
        event loop, 'coro' will be a coroutine object.  The callable
        must return a Future.
        """
        if factory is not None and not callable(factory):
            raise TypeError('task factory must be a callable or None')
        self._task_factory = factory

    def get_task_factory(self):
        """Return a task factory, or None if the default one is in use."""
        return self._task_factory

    def run_until_complete(self, future):
        """Run until the Future is done.

        If the argument is a coroutine, it is wrapped in a Task.

        WARNING: It would be disastrous to call run_until_complete()
        with the same coroutine twice -- it would wrap it in two
        different Tasks and that can't be good.

        Return the Future's result, or raise its exception.
        """
        self._check_closed()

        new_task = not isfuture(future)
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

    def getaddrinfo(self, object host, object port, *,
                    int family=0, int type=0, int proto=0, int flags=0):

        addr = __static_getaddrinfo_pyaddr(host, port, family,
                                           type, proto, flags)
        if addr is not None:
            fut = self._new_future()
            fut.set_result([addr])
            return fut

        return self._getaddrinfo(host, port, family, type, proto, flags, 1)

    async def getnameinfo(self, sockaddr, int flags=0):
        cdef:
            AddrInfo ai_cnt
            system.addrinfo *ai
            system.sockaddr_in6 *sin6

        if not isinstance(sockaddr, tuple):
            raise TypeError('getnameinfo() argument 1 must be a tuple')

        sl = len(sockaddr)

        if sl < 2 or sl > 4:
            raise ValueError('sockaddr must be a tuple of 2, 3 or 4 values')

        if sl > 2:
            flowinfo = sockaddr[2]
            if flowinfo < 0 or flowinfo > 0xfffff:
                raise OverflowError(
                    'getsockaddrarg: flowinfo must be 0-1048575.')
        else:
            flowinfo = 0

        if sl > 3:
            scope_id = sockaddr[3]
            if scope_id < 0 or scope_id > 2 ** 32:
                raise OverflowError(
                    'getsockaddrarg: scope_id must be unsigned 32 bit integer')
        else:
            scope_id = 0

        ai_cnt = await self._getaddrinfo(
            sockaddr[0], sockaddr[1],
            uv.AF_UNSPEC,         # family
            uv.SOCK_DGRAM,        # type
            0,                    # proto
            uv.AI_NUMERICHOST,    # flags
            0)                    # unpack

        ai = ai_cnt.data

        if ai.ai_next:
            raise OSError("sockaddr resolved to multiple addresses")

        if ai.ai_family == uv.AF_INET:
            if sl > 2:
                raise OSError("IPv4 sockaddr must be 2 tuple")
        elif ai.ai_family == uv.AF_INET6:
            # Modify some fields in `ai`
            sin6 = <system.sockaddr_in6*> ai.ai_addr
            sin6.sin6_flowinfo = system.htonl(flowinfo)
            sin6.sin6_scope_id = scope_id

        return await self._getnameinfo(ai.ai_addr, flags)

    async def create_server(self, protocol_factory, host=None, port=None,
                            *,
                            int family=uv.AF_UNSPEC,
                            int flags=uv.AI_PASSIVE,
                            sock=None,
                            backlog=100,
                            ssl=None,
                            reuse_address=None,  # ignored, libuv sets it
                            reuse_port=None):
        """A coroutine which creates a TCP server bound to host and port.

        The return value is a Server object which can be used to stop
        the service.

        If host is an empty string or None all interfaces are assumed
        and a list of multiple sockets will be returned (most likely
        one for IPv4 and another one for IPv6). The host parameter can also be a
        sequence (e.g. list) of hosts to bind to.

        family can be set to either AF_INET or AF_INET6 to force the
        socket to use IPv4 or IPv6. If not set it will be determined
        from host (defaults to AF_UNSPEC).

        flags is a bitmask for getaddrinfo().

        sock can optionally be specified in order to use a preexisting
        socket object.

        backlog is the maximum number of queued connections passed to
        listen() (defaults to 100).

        ssl can be set to an SSLContext to enable SSL over the
        accepted connections.

        reuse_address tells the kernel to reuse a local socket in
        TIME_WAIT state, without waiting for its natural timeout to
        expire. If not specified will automatically be set to True on
        UNIX.

        reuse_port tells the kernel to allow this endpoint to be bound to
        the same port as other existing endpoints are bound to, so long as
        they all set this flag when being created. This option is not
        supported on Windows.
        """
        cdef:
            TCPServer tcp
            system.addrinfo *addrinfo
            Server server

        if sock is not None and sock.family == uv.AF_UNIX:
            if host is not None or port is not None:
                raise ValueError(
                    'host/port and sock can not be specified at the same time')
            return await self.create_unix_server(
                protocol_factory, sock=sock, ssl=ssl)

        server = Server(self)

        if ssl is not None and not isinstance(ssl, ssl_SSLContext):
            raise TypeError('ssl argument must be an SSLContext or None')

        if host is not None or port is not None:
            if sock is not None:
                raise ValueError(
                    'host/port and sock can not be specified at the same time')

            reuse_port = bool(reuse_port)
            if reuse_port and not has_SO_REUSEPORT:
                raise ValueError(
                    'reuse_port not supported by socket module')

            if host == '':
                hosts = [None]
            elif (isinstance(host, str) or not isinstance(host, col_Iterable)):
                hosts = [host]
            else:
                hosts = host

            fs = [self._getaddrinfo(host, port, family,
                                    uv.SOCK_STREAM, 0, flags,
                                    0) for host in hosts]

            infos = await aio_gather(*fs, loop=self)

            completed = False
            try:
                for info in infos:
                    addrinfo = (<AddrInfo>info).data
                    while addrinfo != NULL:
                        if addrinfo.ai_family == uv.AF_UNSPEC:
                            raise RuntimeError('AF_UNSPEC in DNS results')

                        tcp = self._create_server(
                            addrinfo.ai_addr, protocol_factory, server,
                            ssl, reuse_port, backlog)

                        server._add_server(<TCPServer>tcp)

                        addrinfo = addrinfo.ai_next

                completed = True
            finally:
                if not completed:
                    server.close()
        else:
            if sock is None:
                raise ValueError('Neither host/port nor sock were specified')
            if not _is_sock_stream(sock.type):
                raise ValueError(
                    'A Stream Socket was expected, got {!r}'.format(sock))

            tcp = TCPServer.new(self, protocol_factory, server, ssl,
                                uv.AF_UNSPEC)

            # See a comment on os_dup in create_connection
            fileno = os_dup(sock.fileno())
            try:
                tcp._open(fileno)
                tcp._attach_fileobj(sock)
                tcp.listen(backlog)
            except:
                tcp._close()
                raise

            server._add_server(tcp)

        return server

    async def create_connection(self, protocol_factory, host=None, port=None, *,
                                ssl=None, family=0, proto=0, flags=0, sock=None,
                                local_addr=None, server_hostname=None):
        """Connect to a TCP server.

        Create a streaming transport connection to a given Internet host and
        port: socket family AF_INET or socket.AF_INET6 depending on host (or
        family if specified), socket type SOCK_STREAM. protocol_factory must be
        a callable returning a protocol instance.

        This method is a coroutine which will try to establish the connection
        in the background.  When successful, the coroutine returns a
        (transport, protocol) pair.
        """
        cdef:
            AddrInfo ai_local = None
            AddrInfo ai_remote
            TCPTransport tr

            system.addrinfo *rai = NULL
            system.addrinfo *lai = NULL

            system.addrinfo *rai_iter = NULL
            system.addrinfo *lai_iter = NULL

            system.addrinfo rai_static
            system.sockaddr_storage rai_addr_static
            system.addrinfo lai_static
            system.sockaddr_storage lai_addr_static

            object app_protocol
            object protocol
            object ssl_waiter

        if sock is not None and sock.family == uv.AF_UNIX:
            if host is not None or port is not None:
                raise ValueError(
                    'host/port and sock can not be specified at the same time')
            return await self.create_unix_connection(
                protocol_factory, None,
                sock=sock, ssl=ssl, server_hostname=server_hostname)

        app_protocol = protocol = protocol_factory()
        ssl_waiter = None
        if ssl:
            if server_hostname is None:
                if not host:
                    raise ValueError('You must set server_hostname '
                                     'when using ssl without a host')
                server_hostname = host

            ssl_waiter = self._new_future()
            sslcontext = None if isinstance(ssl, bool) else ssl
            protocol = aio_SSLProtocol(
                self, app_protocol, sslcontext, ssl_waiter,
                False, server_hostname)
        else:
            if server_hostname is not None:
                raise ValueError('server_hostname is only meaningful with ssl')

        if host is not None or port is not None:
            if sock is not None:
                raise ValueError(
                    'host/port and sock can not be specified at the same time')

            fs = []
            f1 = f2 = None

            try:
                __static_getaddrinfo(
                    host, port, family, uv.SOCK_STREAM,
                    proto, <system.sockaddr*>&rai_addr_static)
            except LookupError:
                f1 = self._getaddrinfo(
                    host, port, family,
                    uv.SOCK_STREAM, proto, flags,
                    0)  # 0 == don't unpack

                fs.append(f1)
            else:
                rai_static.ai_addr = <system.sockaddr*>&rai_addr_static
                rai_static.ai_next = NULL
                rai = &rai_static

            if local_addr is not None:
                if not isinstance(local_addr, (tuple, list)) or \
                        len(local_addr) != 2:
                    raise ValueError(
                        'local_addr must be a tuple of host and port')

                try:
                    __static_getaddrinfo(
                        local_addr[0], local_addr[1],
                        family, uv.SOCK_STREAM,
                        proto, <system.sockaddr*>&lai_addr_static)
                except LookupError:
                    f2 = self._getaddrinfo(
                        local_addr[0], local_addr[1], family,
                        uv.SOCK_STREAM, proto, flags,
                        0)  # 0 == don't unpack

                    fs.append(f2)
                else:
                    lai_static.ai_addr = <system.sockaddr*>&lai_addr_static
                    lai_static.ai_next = NULL
                    lai = &lai_static

            if len(fs):
                await aio_wait(fs, loop=self)

            if rai is NULL:
                ai_remote = f1.result()
                if ai_remote.data is NULL:
                    raise OSError('getaddrinfo() returned empty list')
                rai = ai_remote.data

            if lai is NULL and f2 is not None:
                ai_local = f2.result()
                if ai_local.data is NULL:
                    raise OSError(
                        'getaddrinfo() returned empty list for local_addr')
                lai = ai_local.data

            exceptions = []
            rai_iter = rai
            while rai_iter is not NULL:
                tr = None
                try:
                    waiter = self._new_future()
                    tr = TCPTransport.new(self, protocol, None, waiter)

                    if lai is not NULL:
                        lai_iter = lai
                        while lai_iter is not NULL:
                            try:
                                tr.bind(lai_iter.ai_addr)
                                break
                            except OSError as exc:
                                exceptions.append(exc)
                            lai_iter = lai_iter.ai_next
                        else:
                            tr._close()
                            tr = None

                            rai_iter = rai_iter.ai_next
                            continue

                    tr.connect(rai_iter.ai_addr)
                    await waiter

                except OSError as exc:
                    if tr is not None:
                        tr._close()
                        tr = None
                    exceptions.append(exc)
                except:
                    if tr is not None:
                        tr._close()
                        tr = None
                    raise
                else:
                    break

                rai_iter = rai_iter.ai_next

            else:
                # If they all have the same str(), raise one.
                model = str(exceptions[0])
                if all(str(exc) == model for exc in exceptions):
                    raise exceptions[0]
                # Raise a combined exception so the user can see all
                # the various error messages.
                raise OSError('Multiple exceptions: {}'.format(
                    ', '.join(str(exc) for exc in exceptions)))
        else:
            if sock is None:
                raise ValueError(
                    'host and port was not specified and no sock specified')
            if not _is_sock_stream(sock.type):
                raise ValueError(
                    'A Stream Socket was expected, got {!r}'.format(sock))

            waiter = self._new_future()
            tr = TCPTransport.new(self, protocol, None, waiter)
            try:
                # Why we use os.dup here and other places
                # ---------------------------------------
                #
                # Prerequisite: in Python 3.6, Python Socket Objects (PSO)
                # were fixed to raise an OSError if the `socket.close()` call
                # failed.  So if the underlying FD is already closed,
                # `socket.close()` call will fail with OSError(EBADF).
                #
                # Problem:
                #
                #   - Vanilla asyncio uses the passed PSO directly.  When the
                #     transport eventually closes the PSO, the PSO is marked as
                #     'closed'.  If the user decides to close the PSO after
                #     closing the loop, everything works normal in Python 3.5
                #     and 3.6.
                #
                #   - asyncio+uvloop unwraps the FD from the passed PSO.
                #     Eventually the transport is closed and so the FD.
                #     If the user decides to close the PSO after closing the
                #     loop, an OSError(EBADF) will be raised in Python 3.6.
                #
                # All in all, duping FDs makes sense, because uvloop
                # (and libuv) manage the FD once the user passes a PSO to
                # `loop.create_connection`.  We don't want the user to have
                # any control of the FD once it is passed to uvloop.
                # See also: https://github.com/python/asyncio/pull/449
                fileno = os_dup(sock.fileno())

                # libuv will make socket non-blocking
                tr._open(fileno)
                tr._attach_fileobj(sock)
                tr._init_protocol()
                await waiter
            except:
                tr._close()
                raise

        if ssl:
            await ssl_waiter
            return protocol._app_transport, app_protocol
        else:
            return tr, protocol

    async def create_unix_server(self, protocol_factory, str path=None,
                                 *, backlog=100, sock=None, ssl=None):
        """A coroutine which creates a UNIX Domain Socket server.

        The return value is a Server object, which can be used to stop
        the service.

        path is a str, representing a file systsem path to bind the
        server socket to.

        sock can optionally be specified in order to use a preexisting
        socket object.

        backlog is the maximum number of queued connections passed to
        listen() (defaults to 100).

        ssl can be set to an SSLContext to enable SSL over the
        accepted connections.
        """
        cdef:
            UnixServer pipe
            Server server = Server(self)

        if ssl is not None and not isinstance(ssl, ssl_SSLContext):
            raise TypeError('ssl argument must be an SSLContext or None')

        if path is not None:
            if sock is not None:
                raise ValueError(
                    'path and sock can not be specified at the same time')

            # We use Python sockets to create a UNIX server socket because
            # when UNIX sockets are created by libuv, libuv removes the path
            # they were bound to.  This is different from asyncio, which
            # doesn't cleanup the socket path.
            sock = socket_socket(uv.AF_UNIX)

            try:
                sock.bind(path)
            except OSError as exc:
                sock.close()
                if exc.errno == errno.EADDRINUSE:
                    # Let's improve the error message by adding
                    # with what exact address it occurs.
                    msg = 'Address {!r} is already in use'.format(path)
                    raise OSError(errno.EADDRINUSE, msg) from None
                else:
                    raise
            except:
                sock.close()
                raise

        else:
            if sock is None:
                raise ValueError(
                    'path was not specified, and no sock specified')

            if sock.family != uv.AF_UNIX or not _is_sock_stream(sock.type):
                raise ValueError(
                    'A UNIX Domain Stream Socket was expected, got {!r}'
                    .format(sock))

        pipe = UnixServer.new(self, protocol_factory, server, ssl)

        try:
            # See a comment on os_dup in create_connection
            fileno = os_dup(sock.fileno())

            pipe._open(fileno)
        except:
            pipe._close()
            sock.close()
            raise

        pipe._attach_fileobj(sock)

        try:
            pipe.listen(backlog)
        except:
            pipe._close()
            raise

        server._add_server(pipe)
        return server

    async def create_unix_connection(self, protocol_factory, path, *,
                                     ssl=None, sock=None,
                                     server_hostname=None):

        cdef:
            UnixTransport tr
            object app_protocol
            object protocol
            object ssl_waiter

        app_protocol = protocol = protocol_factory()
        ssl_waiter = None
        if ssl:
            if server_hostname is None:
                raise ValueError('You must set server_hostname '
                                 'when using ssl without a host')

            ssl_waiter = self._new_future()
            sslcontext = None if isinstance(ssl, bool) else ssl
            protocol = aio_SSLProtocol(
                self, app_protocol, sslcontext, ssl_waiter,
                False, server_hostname)
        else:
            if server_hostname is not None:
                raise ValueError('server_hostname is only meaningful with ssl')

        if path is not None:
            if isinstance(path, str):
                path = PyUnicode_EncodeFSDefault(path)

            if sock is not None:
                raise ValueError(
                    'path and sock can not be specified at the same time')

            waiter = self._new_future()
            tr = UnixTransport.new(self, protocol, None, waiter)
            tr.connect(path)
            try:
                await waiter
            except:
                tr._close()
                raise

        else:
            if sock is None:
                raise ValueError('no path and sock were specified')

            if sock.family != uv.AF_UNIX or not _is_sock_stream(sock.type):
                raise ValueError(
                    'A UNIX Domain Stream Socket was expected, got {!r}'
                    .format(sock))

            waiter = self._new_future()
            tr = UnixTransport.new(self, protocol, None, waiter)
            try:
                # See a comment on os_dup in create_connection
                fileno = os_dup(sock.fileno())

                # libuv will make socket non-blocking
                tr._open(fileno)
                tr._attach_fileobj(sock)
                tr._init_protocol()
                await waiter
            except:
                tr._close()
                raise

        if ssl:
            await ssl_waiter
            return protocol._app_transport, app_protocol
        else:
            return tr, protocol

    def default_exception_handler(self, context):
        """Default exception handler.

        This is called when an exception occurs and no exception
        handler is set, and can be called by a custom exception
        handler that wants to defer to the default behavior.

        The context parameter has the same meaning as in
        `call_exception_handler()`.
        """
        message = context.get('message')
        if not message:
            message = 'Unhandled exception in event loop'

        exception = context.get('exception')
        if exception is not None:
            exc_info = (type(exception), exception, exception.__traceback__)
        else:
            exc_info = False

        log_lines = [message]
        for key in sorted(context):
            if key in {'message', 'exception'}:
                continue
            value = context[key]
            if key == 'source_traceback':
                tb = ''.join(tb_format_list(value))
                value = 'Object created at (most recent call last):\n'
                value += tb.rstrip()
            else:
                try:
                    value = repr(value)
                except Exception as ex:
                    value = ('Exception in __repr__ {!r}; '
                             'value type: {!r}'.format(ex, type(value)))
            log_lines.append('{}: {}'.format(key, value))

        aio_logger.error('\n'.join(log_lines), exc_info=exc_info)

    def get_exception_handler(self):
        """Return an exception handler, or None if the default one is in use.
        """
        return self._exception_handler

    def set_exception_handler(self, handler):
        """Set handler as the new event loop exception handler.

        If handler is None, the default exception handler will
        be set.

        If handler is a callable object, it should have a
        signature matching '(loop, context)', where 'loop'
        will be a reference to the active event loop, 'context'
        will be a dict object (see `call_exception_handler()`
        documentation for details about context).
        """
        if handler is not None and not callable(handler):
            raise TypeError('A callable object or None is expected, '
                            'got {!r}'.format(handler))
        self._exception_handler = handler

    def call_exception_handler(self, context):
        """Call the current event loop's exception handler.

        The context argument is a dict containing the following keys:

        - 'message': Error message;
        - 'exception' (optional): Exception object;
        - 'future' (optional): Future instance;
        - 'handle' (optional): Handle instance;
        - 'protocol' (optional): Protocol instance;
        - 'transport' (optional): Transport instance;
        - 'socket' (optional): Socket instance.

        New keys maybe introduced in the future.

        Note: do not overload this method in an event loop subclass.
        For custom exception handling, use the
        `set_exception_handler()` method.
        """
        if UVLOOP_DEBUG:
            self._debug_exception_handler_cnt += 1

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
        """Add a reader callback."""
        fd = _as_fd(fd)
        self._ensure_fd_no_transport(fd)
        if len(args) == 0:
            args = None
        self._add_reader(fd, new_Handle(self, callback, args))

    def remove_reader(self, fd):
        """Remove a reader callback."""
        fd = _as_fd(fd)
        self._ensure_fd_no_transport(fd)
        self._remove_reader(fd)

    def add_writer(self, fd, callback, *args):
        """Add a writer callback.."""
        fd = _as_fd(fd)
        self._ensure_fd_no_transport(fd)
        if len(args) == 0:
            args = None
        self._add_writer(fd, new_Handle(self, callback, args))

    def remove_writer(self, fd):
        """Remove a writer callback."""
        fd = _as_fd(fd)
        self._ensure_fd_no_transport(fd)
        self._remove_writer(fd)

    def sock_recv(self, sock, n):
        """Receive data from the socket.

        The return value is a bytes object representing the data received.
        The maximum amount of data to be received at once is specified by
        nbytes.

        This method is a coroutine.
        """
        cdef:
            Handle handle
            int fd

        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")

        fut = self._new_future()
        handle = new_MethodHandle3(
            self,
            "Loop._sock_recv",
            <method3_t>self._sock_recv,
            self,
            fut, sock, n)

        fd = sock.fileno()
        self._add_reader(fd, handle)
        return fut

    async def sock_sendall(self, sock, data):
        """Send data to the socket.

        The socket must be connected to a remote socket. This method continues
        to send data from data until either all data has been sent or an
        error occurs. None is returned on success. On error, an exception is
        raised, and there is no way to determine how much data, if any, was
        successfully processed by the receiving end of the connection.

        This method is a coroutine.
        """
        cdef:
            Handle handle
            int n
            int fd

        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")

        if not data:
            return

        try:
            n = sock.send(data)
        except (BlockingIOError, InterruptedError):
            pass
        else:
            if UVLOOP_DEBUG:
                # This can be a partial success, i.e. only part
                # of the data was sent
                self._sock_try_write_total += 1

            if n == len(data):
                return
            if not isinstance(data, memoryview):
                data = memoryview(data)
            data = data[n:]

        fut = self._new_future()
        handle = new_MethodHandle3(
            self,
            "Loop._sock_sendall",
            <method3_t>self._sock_sendall,
            self,
            fut, sock, data)

        fd = sock.fileno()
        self._add_writer(fd, handle)
        return await fut

    def sock_accept(self, sock):
        """Accept a connection.

        The socket must be bound to an address and listening for connections.
        The return value is a pair (conn, address) where conn is a new socket
        object usable to send and receive data on the connection, and address
        is the address bound to the socket on the other end of the connection.

        This method is a coroutine.
        """
        cdef:
            Handle handle
            int fd

        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")

        fut = self._new_future()
        handle = new_MethodHandle2(
            self,
            "Loop._sock_accept",
            <method2_t>self._sock_accept,
            self,
            fut, sock)

        fd = sock.fileno()
        self._add_reader(fd, handle)
        return fut

    async def sock_connect(self, sock, address):
        """Connect to a remote socket at address.

        This method is a coroutine.
        """
        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")

        fut = self._new_future()
        if sock.family == uv.AF_UNIX:
            self._sock_connect(fut, sock, address)
            await fut
            return

        _, _, _, _, address = (await self.getaddrinfo(*address))[0]
        self._sock_connect(fut, sock, address)
        await fut

    async def connect_accepted_socket(self, protocol_factory, sock, *,
                                      ssl=None):
        """Handle an accepted connection.

        This is used by servers that accept connections outside of
        asyncio but that use asyncio to handle connections.

        This method is a coroutine.  When completed, the coroutine
        returns a (transport, protocol) pair.
        """

        cdef:
            UVStream transport = None

        if ssl is not None and not isinstance(ssl, ssl_SSLContext):
            raise TypeError('ssl argument must be an SSLContext or None')
        if not _is_sock_stream(sock.type):
            raise ValueError(
                'A Stream Socket was expected, got {!r}'.format(sock))

        # See a comment on os_dup in create_connection
        fileno = os_dup(sock.fileno())

        app_protocol = protocol_factory()
        waiter = self._new_future()
        transport_waiter = None

        if ssl is None:
            protocol = app_protocol
            transport_waiter = waiter
        else:
            protocol = aio_SSLProtocol(
                self, app_protocol, ssl, waiter,
                True,  # server_side
                None)  # server_hostname
            transport_waiter = None

        if sock.family == uv.AF_UNIX:
            transport = <UVStream>UnixTransport.new(
                self, protocol, None, transport_waiter)
        elif sock.family in (uv.AF_INET, uv.AF_INET6):
            transport = <UVStream>TCPTransport.new(
                self, protocol, None, transport_waiter)

        if transport is None:
            raise ValueError(
                'invalid socket family, expected AF_UNIX, AF_INET or AF_INET6')

        transport._open(fileno)
        transport._init_protocol()

        await waiter
        return transport, protocol

    def run_in_executor(self, executor, func, *args):
        if aio_iscoroutine(func) or aio_iscoroutinefunction(func):
            raise TypeError("coroutines cannot be used with run_in_executor()")

        self._check_closed()

        if executor is None:
            executor = self._default_executor
            if executor is None:
                executor = cc_ThreadPoolExecutor()
                self._default_executor = executor

        new_fut = self._new_future()
        _chain_future(executor.submit(func, *args), new_fut)
        return new_fut

    def set_default_executor(self, executor):
        self._default_executor = executor

    async def __subprocess_run(self, protocol_factory, args,
                               stdin=subprocess_PIPE,
                               stdout=subprocess_PIPE,
                               stderr=subprocess_PIPE,
                               universal_newlines=False,
                               shell=True,
                               bufsize=0,
                               preexec_fn=None,
                               close_fds=None,
                               cwd=None,
                               env=None,
                               startupinfo=None,
                               creationflags=0,
                               restore_signals=True,
                               start_new_session=False,
                               executable=None,
                               pass_fds=(),

                               # For tests only! Do not use in your code. Ever.
                               __uvloop_sleep_after_fork=False
                            ):

        # TODO: Implement close_fds (might not be very important in
        # Python 3.5, since all FDs aren't inheritable by default.)

        cdef:
            int debug_flags = 0

        if universal_newlines:
            raise ValueError("universal_newlines must be False")
        if bufsize != 0:
            raise ValueError("bufsize must be 0")
        if startupinfo is not None:
            raise ValueError('startupinfo is not supported')
        if creationflags != 0:
            raise ValueError('creationflags is not supported')

        if executable is not None:
            args[0] = executable

        if __uvloop_sleep_after_fork:
            debug_flags |= __PROCESS_DEBUG_SLEEP_AFTER_FORK

        waiter = self._new_future()
        protocol = protocol_factory()
        proc = UVProcessTransport.new(self, protocol,
                                      args, env, cwd, start_new_session,
                                      stdin, stdout, stderr, pass_fds,
                                      waiter,
                                      debug_flags,
                                      preexec_fn,
                                      restore_signals)

        try:
            await waiter
        except:
            proc.close()
            raise

        return proc, protocol

    def subprocess_shell(self, protocol_factory, cmd, *,
                         shell=True,
                         **kwargs):

        if not shell:
            raise ValueError("shell must be True")

        args = [cmd]
        if shell:
            args = [b'/bin/sh', b'-c'] + args

        return self.__subprocess_run(protocol_factory, args, shell=True,
                                     **kwargs)

    def subprocess_exec(self,  protocol_factory, program, *args,
                        shell=False, **kwargs):

        if shell:
            raise ValueError("shell must be False")

        args = list((program,) + args)

        return self.__subprocess_run(protocol_factory, args, shell=False,
                                     **kwargs)

    async def connect_read_pipe(self, proto_factory, pipe):
        """Register read pipe in event loop. Set the pipe to non-blocking mode.

        protocol_factory should instantiate object with Protocol interface.
        pipe is a file-like object.
        Return pair (transport, protocol), where transport supports the
        ReadTransport interface."""
        cdef:
            ReadUnixTransport transp
            # See a comment on os_dup in create_connection
            int fileno = os_dup(pipe.fileno())

        waiter = self._new_future()
        proto = proto_factory()
        transp = ReadUnixTransport.new(self, proto, None, waiter)
        transp._add_extra_info('pipe', pipe)
        transp._attach_fileobj(pipe)
        try:
            transp._open(fileno)
            transp._init_protocol()
            await waiter
        except:
            transp.close()
            raise
        return transp, proto

    async def connect_write_pipe(self, proto_factory, pipe):
        """Register write pipe in event loop.

        protocol_factory should instantiate object with BaseProtocol interface.
        Pipe is file-like object already switched to nonblocking.
        Return pair (transport, protocol), where transport support
        WriteTransport interface."""
        cdef:
            WriteUnixTransport transp
            # See a comment on os_dup in create_connection
            int fileno = os_dup(pipe.fileno())

        waiter = self._new_future()
        proto = proto_factory()
        transp = WriteUnixTransport.new(self, proto, None, waiter)
        transp._add_extra_info('pipe', pipe)
        transp._attach_fileobj(pipe)
        try:
            transp._open(fileno)
            transp._init_protocol()
            await waiter
        except:
            transp.close()
            raise
        return transp, proto

    def add_signal_handler(self, sig, callback, *args):
        """Add a handler for a signal.  UNIX only.

        Raise ValueError if the signal number is invalid or uncatchable.
        Raise RuntimeError if there is a problem setting up the handler.
        """
        cdef:
            Handle h

        if self._signal_handlers is None:
            self._setup_signals()
            if self._signal_handlers is None:
                raise ValueError('set_wakeup_fd only works in main thread')

        if (aio_iscoroutine(callback)
                or aio_iscoroutinefunction(callback)):
            raise TypeError("coroutines cannot be used "
                            "with add_signal_handler()")

        self._check_signal(sig)
        self._check_closed()

        try:
            # set_wakeup_fd() raises ValueError if this is not the
            # main thread.  By calling it early we ensure that an
            # event loop running in another thread cannot add a signal
            # handler.
            signal_set_wakeup_fd(self._csock.fileno())
        except (ValueError, OSError) as exc:
            raise RuntimeError(str(exc))

        h = new_Handle(self, callback, args or None)
        self._signal_handlers[sig] = h

        try:
            signal_signal(sig, _sighandler_noop)
        except OSError as exc:
            del self._signal_handlers[sig]
            if exc.errno == errno_EINVAL:
                raise RuntimeError('sig {} cannot be caught'.format(sig))
            else:
                raise

    def remove_signal_handler(self, sig):
        """Remove a handler for a signal.  UNIX only.

        Return True if a signal handler was removed, False if not.
        """
        self._check_signal(sig)

        if self._signal_handlers is None:
            return False

        try:
            del self._signal_handlers[sig]
        except KeyError:
            return False

        if sig == uv.SIGINT:
            handler = signal_default_int_handler
        else:
            handler = signal_SIG_DFL

        try:
            signal_signal(sig, handler)
        except OSError as exc:
            if exc.errno == errno_EINVAL:
                raise RuntimeError('sig {} cannot be caught'.format(sig))
            else:
                raise

        return True

    async def create_datagram_endpoint(self, protocol_factory,
                                       local_addr=None, remote_addr=None, *,
                                       family=0, proto=0, flags=0,
                                       reuse_address=None, reuse_port=None,
                                       allow_broadcast=None, sock=None):
        """A coroutine which creates a datagram endpoint.

        This method will try to establish the endpoint in the background.
        When successful, the coroutine returns a (transport, protocol) pair.

        protocol_factory must be a callable returning a protocol instance.

        socket family AF_INET or socket.AF_INET6 depending on host (or
        family if specified), socket type SOCK_DGRAM.

        reuse_address tells the kernel to reuse a local socket in
        TIME_WAIT state, without waiting for its natural timeout to
        expire. If not specified it will automatically be set to True on
        UNIX.

        reuse_port tells the kernel to allow this endpoint to be bound to
        the same port as other existing endpoints are bound to, so long as
        they all set this flag when being created. This option is not
        supported on Windows and some UNIX's. If the
        :py:data:`~socket.SO_REUSEPORT` constant is not defined then this
        capability is unsupported.

        allow_broadcast tells the kernel to allow this endpoint to send
        messages to the broadcast address.

        sock can optionally be specified in order to use a preexisting
        socket object.
        """
        cdef:
            UDPTransport udp = None
            system.addrinfo * lai
            system.addrinfo * rai

        if sock is not None:
            if not _is_sock_dgram(sock.type):
                raise ValueError(
                    'A UDP Socket was expected, got {!r}'.format(sock))
            if (local_addr or remote_addr or
                    family or proto or flags or
                    reuse_address or reuse_port or allow_broadcast):
                # show the problematic kwargs in exception msg
                opts = dict(local_addr=local_addr, remote_addr=remote_addr,
                            family=family, proto=proto, flags=flags,
                            reuse_address=reuse_address, reuse_port=reuse_port,
                            allow_broadcast=allow_broadcast)
                problems = ', '.join(
                    '{}={}'.format(k, v) for k, v in opts.items() if v)
                raise ValueError(
                    'socket modifier keyword arguments can not be used '
                    'when sock is specified. ({})'.format(problems))
            sock.setblocking(False)
            udp = UDPTransport.__new__(UDPTransport)
            udp._init(self, uv.AF_UNSPEC)
            udp.open(sock.family, os_dup(sock.fileno()))
            udp._attach_fileobj(sock)
        else:
            reuse_address = bool(reuse_address)
            reuse_port = bool(reuse_port)
            if reuse_port and not has_SO_REUSEPORT:
                raise ValueError(
                    'reuse_port not supported by socket module')

            lads = None
            if local_addr is not None:
                if (not isinstance(local_addr, (tuple, list)) or
                        len(local_addr) != 2):
                    raise TypeError(
                        'local_addr must be a tuple of (host, port)')
                lads = await self._getaddrinfo(
                    local_addr[0], local_addr[1],
                    family, uv.SOCK_DGRAM, proto, flags,
                    0)

            rads = None
            if remote_addr is not None:
                if (not isinstance(remote_addr, (tuple, list)) or
                        len(remote_addr) != 2):
                    raise TypeError(
                        'remote_addr must be a tuple of (host, port)')
                rads = await self._getaddrinfo(
                    remote_addr[0], remote_addr[1],
                    family, uv.SOCK_DGRAM, proto, flags,
                    0)

            excs = []
            if lads is None:
                if rads is not None:
                    udp = UDPTransport.__new__(UDPTransport)
                    rai = (<AddrInfo>rads).data
                    udp._init(self, rai.ai_family)
                    udp._set_remote_address(rai.ai_addr, rai.ai_addrlen)
                else:
                    if family not in (uv.AF_INET, uv.AF_INET6):
                        raise ValueError('unexpected address family')
                    udp = UDPTransport.__new__(UDPTransport)
                    udp._init(self, family)

                if reuse_port:
                    self._sock_set_reuseport(udp._fileno())

                socket = udp._get_socket()
                socket.bind(('0.0.0.0', 0))
            else:
                lai = (<AddrInfo>lads).data
                while lai is not NULL:
                    try:
                        udp = UDPTransport.__new__(UDPTransport)
                        udp._init(self, lai.ai_family)
                        if reuse_port:
                            self._sock_set_reuseport(udp._fileno())
                        udp._bind(lai.ai_addr, reuse_address)
                    except Exception as ex:
                        lai = lai.ai_next
                        excs.append(ex)
                        continue
                    else:
                        break
                else:
                    ctx = None
                    if len(excs):
                        ctx = excs[0]
                    raise OSError('could not bind to local_addr {}'.format(
                        local_addr)) from ctx

                if rads is not None:
                    rai = (<AddrInfo>rads).data
                    sock = udp._get_socket()
                    while rai is not NULL:
                        if rai.ai_family != lai.ai_family:
                            rai = rai.ai_next
                            continue
                        if rai.ai_protocol != lai.ai_protocol:
                            rai = rai.ai_next
                            continue
                        udp._set_remote_address(rai.ai_addr, rai.ai_addrlen)
                        break
                    else:
                        raise OSError(
                            'could not bind to remote_addr {}'.format(
                                remote_addr))

                    udp._set_remote_address(rai.ai_addr, rai.ai_addrlen)

        if allow_broadcast:
            udp._set_broadcast(1)

        protocol = protocol_factory()
        waiter = self._new_future()
        assert udp is not None
        udp._set_protocol(protocol)
        udp._set_waiter(waiter)
        udp._init_protocol()

        await waiter
        return udp, protocol

    def _asyncgen_finalizer_hook(self, agen):
        self._asyncgens.discard(agen)
        if not self.is_closed():
            self.create_task(agen.aclose())
            # Wake up the loop if the finalizer was called from
            # a different thread.
            self.handler_async.send()

    def _asyncgen_firstiter_hook(self, agen):
        if self._asyncgens_shutdown_called:
            warnings_warn(
                "asynchronous generator {!r} was scheduled after "
                "loop.shutdown_asyncgens() call".format(agen),
                ResourceWarning, source=self)

        self._asyncgens.add(agen)

    async def shutdown_asyncgens(self):
        """Shutdown all active asynchronous generators."""
        self._asyncgens_shutdown_called = True

        if self._asyncgens is None or not len(self._asyncgens):
            # If Python version is <3.6 or we don't have any asynchronous
            # generators alive.
            return

        closing_agens = list(self._asyncgens)
        self._asyncgens.clear()

        shutdown_coro = aio_gather(
            *[ag.aclose() for ag in closing_agens],
            return_exceptions=True,
            loop=self)

        results = await shutdown_coro
        for result, agen in zip(results, closing_agens):
            if isinstance(result, Exception):
                self.call_exception_handler({
                    'message': 'an error occurred during closing of '
                               'asynchronous generator {!r}'.format(agen),
                    'exception': result,
                    'asyncgen': agen
                })


cdef void __loop_alloc_buffer(uv.uv_handle_t* uvhandle,
                              size_t suggested_size,
                              uv.uv_buf_t* buf) with gil:
    cdef:
        Loop loop = (<UVHandle>uvhandle.data)._loop

    if loop._recv_buffer_in_use == 1:
        buf.len = 0
        exc = RuntimeError('concurrent allocations')
        loop._handle_exception(exc)
        return

    loop._recv_buffer_in_use = 1
    buf.base = loop._recv_buffer
    buf.len = sizeof(loop._recv_buffer)


cdef inline void __loop_free_buffer(Loop loop):
    loop._recv_buffer_in_use = 0


include "cbhandles.pyx"

include "handles/handle.pyx"
include "handles/async_.pyx"
include "handles/idle.pyx"
include "handles/check.pyx"
include "handles/timer.pyx"
include "handles/poll.pyx"
include "handles/basetransport.pyx"
include "handles/stream.pyx"
include "handles/streamserver.pyx"
include "handles/tcp.pyx"
include "handles/pipe.pyx"
include "handles/process.pyx"

include "request.pyx"
include "dns.pyx"

include "handles/udp.pyx"

include "server.pyx"

include "future.pyx"
include "chain_futs.pyx"


# Used in UVProcess
cdef vint __atfork_installed = 0
cdef vint __forking = 0
cdef Loop __forking_loop = None


cdef void __atfork_child() nogil:
    # See CPython/posixmodule.c for details
    global __forking

    with gil:
        if (__forking and
                __forking_loop is not None and
                __forking_loop.active_process_handler is not None):

            __forking_loop.active_process_handler._after_fork()


cdef __install_atfork():
    global __atfork_installed
    if __atfork_installed:
        return
    __atfork_installed = 1

    cdef int err

    err = system.pthread_atfork(NULL, NULL, &__atfork_child)
    if err:
        __atfork_installed = 0
        raise convert_error(-err)


# Install PyMem* memory allocators
cdef vint __mem_installed = 0
cdef __install_pymem():
    global __mem_installed
    if __mem_installed:
        return
    __mem_installed = 1

    cdef int err
    err = uv.uv_replace_allocator(<uv.uv_malloc_func>PyMem_RawMalloc,
                                  <uv.uv_realloc_func>PyMem_RawRealloc,
                                  <uv.uv_calloc_func>PyMem_RawCalloc,
                                  <uv.uv_free_func>PyMem_RawFree)
    if err < 0:
        __mem_installed = 0
        raise convert_error(err)


def _sighandler_noop(signum, frame):
    """Dummy signal handler."""
    pass


########### Stuff for tests:

async def _test_coroutine_1():
    return 42
