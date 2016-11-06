# LICENSE: PSF.

DEF _FUT_PENDING = 1
DEF _FUT_CANCELLED = 2
DEF _FUT_FINISHED = 3


cdef inline _future_get_blocking(fut):
    try:
        return fut._asyncio_future_blocking
    except AttributeError:
        return fut._blocking


cdef inline _future_set_blocking(fut, val):
    try:
        fut._asyncio_future_blocking
    except AttributeError:
        fut._blocking = val
    else:
        fut._asyncio_future_blocking = val


cdef class BaseFuture:
    cdef:
        int _state

        readonly Loop _loop
        readonly list _callbacks
        readonly object _exception
        readonly object _result
        public bint _blocking
        readonly object _source_traceback
        readonly bint _log_traceback

    def __init__(self, Loop loop):
        if loop is None:
            loop = aio_get_event_loop()
            if not isinstance(loop, Loop):
                raise TypeError('uvloop.Future supports only uvloop.Loop')

        self._state = _FUT_PENDING
        self._loop = loop
        self._callbacks = []
        self._result = None
        self._exception = None
        self._blocking = False
        self._log_traceback = False

        if loop._debug:
            self._source_traceback = tb_extract_stack(sys_getframe(0))
        else:
            self._source_traceback = None

    property _asyncio_future_blocking:
        def __get__(self):
            return self._blocking

        def __set__(self, value):
            self._blocking = value

    cdef _schedule_callbacks(self):
        cdef:
            list callbacks
            size_t cb_len = len(self._callbacks)
            size_t i

        if cb_len == 0:
            return

        callbacks = self._callbacks
        self._callbacks = []

        for i from 0 <= i < cb_len:
            self._loop.call_soon(callbacks[i], self)

    cdef _add_done_callback(self, fn):
        if self._state != _FUT_PENDING:
            self._loop.call_soon(fn, self)
        else:
            self._callbacks.append(fn)

    cdef _done(self):
        return self._state != _FUT_PENDING

    cdef _cancel(self):
        if self._done():
            return False
        self._state = _FUT_CANCELLED
        self._schedule_callbacks()
        return True

    # _result would shadow the "_result" property
    cdef _result_impl(self):
        if self._state == _FUT_CANCELLED:
            raise aio_CancelledError
        if self._state != _FUT_FINISHED:
            raise aio_InvalidStateError('Result is not ready.')
        self._log_traceback = False
        if self._exception is not None:
            raise self._exception
        return self._result

    cdef _str_state(self):
        if self._state == _FUT_PENDING:
            return 'PENDING'
        elif self._state == _FUT_CANCELLED:
            return 'CANCELLED'
        elif self._state == _FUT_FINISHED:
            return 'FINISHED'
        else:
            raise RuntimeError('unknown Future state')

    property _state:
        def __get__(self):
            return self._str_state()

    def cancel(self):
        """Cancel the future and schedule callbacks.

        If the future is already done or cancelled, return False.  Otherwise,
        change the future's state to cancelled, schedule the callbacks and
        return True.
        """
        return self._cancel()

    def cancelled(self):
        """Return True if the future was cancelled."""
        return self._state == _FUT_CANCELLED

    def done(self):
        """Return True if the future is done.

        Done means either that a result / exception are available, or that the
        future was cancelled.
        """
        return self._state != _FUT_PENDING

    def result(self):
        """Return the result this future represents.

        If the future has been cancelled, raises CancelledError.  If the
        future's result isn't yet available, raises InvalidStateError.  If
        the future is done and has an exception set, this exception is raised.
        """
        return self._result_impl()

    def exception(self):
        """Return the exception that was set on this future.

        The exception (or None if no exception was set) is returned only if
        the future is done.  If the future has been cancelled, raises
        CancelledError.  If the future isn't done yet, raises
        InvalidStateError.
        """
        if self._state == _FUT_CANCELLED:
            raise aio_CancelledError
        if self._state != _FUT_FINISHED:
            raise aio_InvalidStateError('Exception is not set.')
        self._log_traceback = False
        return self._exception

    def add_done_callback(self, fn):
        """Add a callback to be run when the future becomes done.

        The callback is called with a single argument - the future object. If
        the future is already done when this is called, the callback is
        scheduled with call_soon.
        """
        self._add_done_callback(fn)

    def remove_done_callback(self, fn):
        """Remove all instances of a callback from the "call when done" list.

        Returns the number of callbacks removed.
        """
        cdef:
            size_t clen = len(self._callbacks)
            size_t i
            size_t ni = 0
            object cb

        for i from 0 <= i < clen:
            cb = self._callbacks[i]
            if cb != fn:
                self._callbacks[ni] = cb
                ni += 1

        if ni != clen:
            del self._callbacks[ni:]

        return clen - ni

    cpdef set_result(self, result):
        """Mark the future done and set its result.

        If the future is already done when this method is called, raises
        InvalidStateError.
        """
        if self._state != _FUT_PENDING:
            raise aio_InvalidStateError('{}: {!r}'.format(
                self._str_state(), self))
        self._result = result
        self._state = _FUT_FINISHED
        self._schedule_callbacks()

    cpdef set_exception(self, exception):
        """Mark the future done and set an exception.

        If the future is already done when this method is called, raises
        InvalidStateError.
        """
        if self._state != _FUT_PENDING:
            raise aio_InvalidStateError('{}: {!r}'.format(
                self._str_state(), self))
        if isinstance(exception, type):
            exception = exception()
        if type(exception) is StopIteration:
            raise TypeError("StopIteration interacts badly with generators "
                            "and cannot be raised into a Future")
        self._exception = exception
        self._state = _FUT_FINISHED
        self._schedule_callbacks()
        self._log_traceback = True

    # Copy of __await__
    def __iter__(self):
        if self._state == _FUT_PENDING:
            self._blocking = True
            yield self  # This tells Task to wait for completion.

        if self._state == _FUT_PENDING:
            raise AssertionError("yield from wasn't used with future")

        return self._result_impl()  # May raise too.

    # Copy of __iter__
    def __await__(self):
        if self._state == _FUT_PENDING:
            self._blocking = True
            yield self  # This tells Task to wait for completion.

        if self._state == _FUT_PENDING:
            raise AssertionError("yield from wasn't used with future")

        return self._result_impl()  # May raise too.


cdef class BaseTask(BaseFuture):
    cdef:
        readonly object _coro
        readonly object _fut_waiter
        readonly bint _must_cancel
        public bint _log_destroy_pending

    def __init__(self, coro not None, Loop loop):
        BaseFuture.__init__(self, loop)

        self._coro = coro
        self._fut_waiter = None
        self._must_cancel = False
        self._log_destroy_pending = True

        self.__class__._all_tasks.add(self)

        self._loop._call_soon_handle(
            new_MethodHandle1(
                self._loop,
                "Task._step",
                <method1_t>self._fast_step,
                self,
                None))

    def cancel(self):
        if self.done():
            return False
        if self._fut_waiter is not None:
            if self._fut_waiter.cancel():
                # Leave self._fut_waiter; it may be a Task that
                # catches and ignores the cancellation so we may have
                # to cancel it again later.
                return True
        # It must be the case that self._step is already scheduled.
        self._must_cancel = True
        return True

    cdef _raise_wrong_loop(self, fut):
        ex = RuntimeError(
            'Task {!r} got Future {!r} attached to a '
            'different loop'.format(self, fut))
        self._loop._call_soon_handle(
            new_MethodHandle1(
                self._loop,
                "Task._step",
                <method1_t>self._fast_step,
                self,
                ex))

    cdef _raise_yield(self, fut):
        ex = RuntimeError(
            'yield was used instead of yield from '
            'in task {!r} with {!r}'.format(self, fut))
        self._loop._call_soon_handle(
            new_MethodHandle1(
                self._loop,
                "Task._step",
                <method1_t>self._fast_step,
                self,
                ex))

    cdef _raise_generator(self, val):
        ex = RuntimeError(
            'yield was used instead of yield from for '
            'generator in task {!r} with {}'.format(self, val))
        self._loop._call_soon_handle(
            new_MethodHandle1(
                self._loop,
                "Task._step",
                <method1_t>self._fast_step,
                self,
                ex))

    cdef _raise_else(self, val):
        ex = RuntimeError('Task got bad yield: {!r}'.format(val))
        self._loop._call_soon_handle(
            new_MethodHandle1(
                self._loop,
                "Task._step",
                <method1_t>self._fast_step,
                self,
                ex))

    cdef _skip_oneloop(self):
        self._loop._call_soon_handle(
            new_MethodHandle1(
                self._loop,
                "Task._step",
                <method1_t>self._fast_step,
                self,
                None))

    cdef _fast_step(self, exc):
        cdef:
            BaseFuture nfut
            object meth
            object _current_tasks = self.__class__._current_tasks

        if self._state != _FUT_PENDING:
            raise AssertionError(
                '_step(): already done: {!r}, {!r}'.format(self, exc))

        if self._must_cancel:
            if not isinstance(exc, aio_CancelledError):
                exc = aio_CancelledError()
            self._must_cancel = False

        self._fut_waiter = None

        # Let it fail early with an AttributeError if self._coro
        # is not a coroutine/generator.
        if exc is None:
            meth = self._coro.send
        else:
            meth = self._coro.throw

        _current_tasks[self._loop] = self
        # Call either coro.throw(exc) or coro.send(None).
        try:
            if exc is None:
                # We use the `send` method directly, because coroutines
                # don't have `__iter__` and `__next__` methods.
                result = meth(None)
            else:
                result = meth(exc)
        except StopIteration as exc:
            self.set_result(exc.value)
        except aio_CancelledError as exc:
            BaseFuture._cancel(self)  # I.e., Future.cancel(self).
        except Exception as exc:
            self.set_exception(exc)
        except BaseException as exc:
            self.set_exception(exc)
            raise
        else:
            result_type = type(result)
            if result_type is uvloop_Future:
                # Yielded Future must come from Future.__iter__().
                nfut = <BaseFuture>result
                if nfut._loop is not self._loop:
                    self._raise_wrong_loop(result)
                elif nfut._blocking:
                    nfut._blocking = False
                    nfut._add_done_callback(self._wakeup)
                    self._fut_waiter = result
                    if self._must_cancel:
                        if self._fut_waiter.cancel():
                            self._must_cancel = False
                else:
                    self._raise_yield(result)

            elif result_type is aio_Future or isfuture(result):
                # Yielded Future must come from Future.__iter__().
                if result._loop is not self._loop:
                    self._raise_wrong_loop(result)
                elif _future_get_blocking(result):
                    _future_set_blocking(result, False)
                    result.add_done_callback(self._wakeup)
                    self._fut_waiter = result
                    if self._must_cancel:
                        if self._fut_waiter.cancel():
                            self._must_cancel = False
                else:
                    self._raise_yield(result)

            elif result is None:
                # Bare yield relinquishes control for one event loop iteration.
                self._skip_oneloop()

            elif inspect_isgenerator(result):
                # Yielding a generator is just wrong.
                self._raise_generator(result)

            else:
                # Yielding something else is an error.
                self._raise_else(result)
        finally:
            _current_tasks.pop(self._loop)

    cdef _fast_wakeup(self, future):
        try:
            if type(future) is uvloop_Future:
                (<BaseFuture>future)._result_impl()
            else:
                future.result()
        except Exception as exc:
            # This may also be a cancellation.
            self._fast_step(exc)
        else:
            # Don't pass the value of `future.result()` explicitly,
            # as `Future.__iter__` and `Future.__await__` don't need it.
            self._fast_step(None)

    def _step(self, exc=None):
        self._fast_step(exc)
        self = None

    def _wakeup(self, future):
        self._fast_wakeup(future)
        self = None


cdef uvloop_Future = None

cdef future_factory
cdef task_factory


if sys.version_info >= (3, 6):
    # In Python 3.6 Task and Future are implemented in C and
    # are already fast.

    future_factory = aio_Future
    task_factory = aio_Task

    Future = aio_Future

else:
    class Future(BaseFuture, aio_Future):
        # Inherit asyncio.Future.__del__ and __repr__
        pass


    class Task(BaseTask, aio_Task):
        # Inherit asyncio.Task.__del__ and __repr__ and a bunch
        # of class methods.
        pass

    uvloop_Future = Future

    future_factory = Future
    task_factory = Task


cdef _is_uvloop_future(fut):
    return uvloop_Future is not None and type(fut) == uvloop_Future
