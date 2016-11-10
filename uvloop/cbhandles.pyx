@cython.no_gc_clear
@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class Handle:
    def __cinit__(self):
        self.cancelled = 0
        self.cb_type = 0
        self._source_traceback = None

    cdef inline _set_loop(self, Loop loop):
        self.loop = loop
        if UVLOOP_DEBUG:
            loop._debug_cb_handles_total += 1
            loop._debug_cb_handles_count += 1
        if loop._debug:
            self._source_traceback = tb_extract_stack(sys_getframe(0))

    def __dealloc__(self):
        if UVLOOP_DEBUG and self.loop is not None:
            self.loop._debug_cb_handles_count -= 1
        if self.loop is None:
            raise RuntimeError('Handle.loop is None in Handle.__dealloc__')

    def __init__(self):
        raise TypeError(
            '{} is not supposed to be instantiated from Python'.format(
                self.__class__.__name__))

    cdef inline _run(self):
        cdef:
            int cb_type
            object callback

        if self.cancelled:
            return

        cb_type = self.cb_type

        Py_INCREF(self)   # Since _run is a cdef and there's no BoundMethod,
                          # we guard 'self' manually (since the callback
                          # might cause GC of the handle.)
        try:
            if cb_type == 1:
                callback = self.arg1
                args = self.arg2

                if args is None:
                    callback()
                else:
                    callback(*args)

            elif cb_type == 2:
                (<method_t>self.callback)(self.arg1)

            elif cb_type == 3:
                (<method1_t>self.callback)(self.arg1, self.arg2)

            elif cb_type == 4:
                (<method2_t>self.callback)(self.arg1, self.arg2, self.arg3)

            elif cb_type == 5:
                (<method3_t>self.callback)(
                    self.arg1, self.arg2, self.arg3, self.arg4)

            else:
                raise RuntimeError('invalid Handle.cb_type: {}'.format(
                    cb_type))

        except Exception as ex:
            if cb_type == 1:
                msg = 'Exception in callback {}'.format(callback)
            else:
                msg = 'Exception in callback {}'.format(self.meth_name)

            context = {
                'message': msg,
                'exception': ex,
                'handle': self,
            }

            if self._source_traceback is not None:
                context['source_traceback'] = self._source_traceback

            self.loop.call_exception_handler(context)

        finally:
            Py_DECREF(self)

    cdef _cancel(self):
        self.cancelled = 1
        self.callback = NULL
        self.arg2 = self.arg3 = self.arg4 = None

    # Public API

    def __repr__(self):
        info = [self.__class__.__name__]

        if self.cancelled:
            info.append('cancelled')

        if self.cb_type == 1:
            func = self.arg1
            if hasattr(func, '__qualname__'):
                cb_name = getattr(func, '__qualname__')
            elif hasattr(func, '__name__'):
                cb_name = getattr(func, '__name__')
            else:
                cb_name = repr(func)

            info.append(cb_name)
        else:
            info.append(self.meth_name)

        if self._source_traceback is not None:
            frame = self._source_traceback[-1]
            info.append('created at {}:{}'.format(frame[0], frame[1]))

        return '<' + ' '.join(info) + '>'

    def cancel(self):
        self._cancel()


@cython.no_gc_clear
@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class TimerHandle:
    def __cinit__(self, Loop loop, object callback, object args,
                  uint64_t delay):

        self.loop = loop
        self.callback = callback
        self.args = args
        self.closed = 0

        if loop._debug:
            self._source_traceback = tb_extract_stack(sys_getframe(0))

        self.timer = UVTimer.new(
            loop, <method_t>self._run, self, delay)

        self.timer.start()

        # Only add to loop._timers when `self.timer` is successfully created
        loop._timers.add(self)

        if UVLOOP_DEBUG:
            self.loop._debug_cb_timer_handles_total += 1
            self.loop._debug_cb_timer_handles_count += 1

    def __dealloc__(self):
        if UVLOOP_DEBUG:
            self.loop._debug_cb_timer_handles_count -= 1
        if self.closed == 0:
            raise RuntimeError('active TimerHandle is deallacating')

    cdef _cancel(self):
        if self.closed == 1:
            return
        self.closed = 1

        self.callback = None
        self.args = None

        try:
            self.loop._timers.remove(self)
        finally:
            self.timer._close()
            self.timer = None  # let it die asap

    cdef _run(self):
        if self.closed == 1:
            return

        callback = self.callback
        args = self.args
        self._cancel()

        Py_INCREF(self)  # Since _run is a cdef and there's no BoundMethod,
                         # we guard 'self' manually.
        if self.loop._debug:
            started = time_monotonic()
        try:
            if args is not None:
                callback(*args)
            else:
                callback()
        except Exception as ex:
            context = {
                'message': 'Exception in callback {}'.format(callback),
                'exception': ex,
                'handle': self,
            }

            if self._source_traceback is not None:
                context['source_traceback'] = self._source_traceback

            self.loop.call_exception_handler(context)
        else:
            if self.loop._debug:
                delta = time_monotonic() - started
                if delta > self.loop.slow_callback_duration:
                    aio_logger.warning(
                        'Executing %r took %.3f seconds',
                        self, delta)
        finally:
            Py_DECREF(self)

    # Public API

    def __repr__(self):
        info = [self.__class__.__name__]

        if self.closed:
            info.append('cancelled')

        func = self.callback
        if hasattr(func, '__qualname__'):
            cb_name = getattr(func, '__qualname__')
        elif hasattr(func, '__name__'):
            cb_name = getattr(func, '__name__')
        else:
            cb_name = repr(func)

        info.append(cb_name)

        if self._source_traceback is not None:
            frame = self._source_traceback[-1]
            info.append('created at {}:{}'.format(frame[0], frame[1]))

        return '<' + ' '.join(info) + '>'

    def cancel(self):
        self._cancel()


cdef new_Handle(Loop loop, object callback, object args):
    cdef Handle handle
    handle = Handle.__new__(Handle)
    handle._set_loop(loop)

    handle.cb_type = 1

    handle.arg1 = callback
    handle.arg2 = args

    return handle


cdef new_MethodHandle(Loop loop, str name, method_t callback, object ctx):
    cdef Handle handle
    handle = Handle.__new__(Handle)
    handle._set_loop(loop)

    handle.cb_type = 2
    handle.meth_name = name

    handle.callback = <void*> callback
    handle.arg1 = ctx

    return handle


cdef new_MethodHandle1(Loop loop, str name, method1_t callback,
                       object ctx, object arg):

    cdef Handle handle
    handle = Handle.__new__(Handle)
    handle._set_loop(loop)

    handle.cb_type = 3
    handle.meth_name = name

    handle.callback = <void*> callback
    handle.arg1 = ctx
    handle.arg2 = arg

    return handle

cdef new_MethodHandle2(Loop loop, str name, method2_t callback, object ctx,
                       object arg1, object arg2):

    cdef Handle handle
    handle = Handle.__new__(Handle)
    handle._set_loop(loop)

    handle.cb_type = 4
    handle.meth_name = name

    handle.callback = <void*> callback
    handle.arg1 = ctx
    handle.arg2 = arg1
    handle.arg3 = arg2

    return handle

cdef new_MethodHandle3(Loop loop, str name, method3_t callback, object ctx,
                       object arg1, object arg2, object arg3):

    cdef Handle handle
    handle = Handle.__new__(Handle)
    handle._set_loop(loop)

    handle.cb_type = 5
    handle.meth_name = name

    handle.callback = <void*> callback
    handle.arg1 = ctx
    handle.arg2 = arg1
    handle.arg3 = arg2
    handle.arg4 = arg3

    return handle
