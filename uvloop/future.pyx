# LICENSE: PSF.

DEF _FUT_PENDING = 1
DEF _FUT_CANCELLED = 2
DEF _FUT_FINISHED = 3


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


class Future(BaseFuture, aio_Future):
    # Inherit asyncio.Future.__del__ and __repr__
    pass


cdef uvloop_Future = Future
