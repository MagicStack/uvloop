# LICENSE: PSF.

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
                <method1_t*>&self._fast_step,
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
                <method1_t*>&self._fast_step,
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
                <method1_t*>&self._fast_step,
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
                <method1_t*>&self._fast_step,
                self,
                ex))

    cdef _raise_else(self, val):
        ex = RuntimeError('Task got bad yield: {!r}'.format(val))
        self._loop._call_soon_handle(
            new_MethodHandle1(
                self._loop,
                "Task._step",
                <method1_t*>&self._fast_step,
                self,
                ex))

    cdef _skip_oneloop(self):
        self._loop._call_soon_handle(
            new_MethodHandle1(
                self._loop,
                "Task._step",
                <method1_t*>&self._fast_step,
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

            elif result_type is aio_Future or isinstance(result, aio_Future):
                # Yielded Future must come from Future.__iter__().
                if result._loop is not self._loop:
                    self._raise_wrong_loop(result)
                elif result._blocking:
                    result._blocking = False
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


class Task(BaseTask, aio_Task):
    # Inherit asyncio.Task.__del__ and __repr__ and a bunch
    # of class methods.
    pass


cdef uvloop_Task = Task
