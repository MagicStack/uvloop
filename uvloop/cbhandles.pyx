@cython.internal
@cython.no_gc_clear
@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class Handle:
    def __cinit__(self):
        self.cancelled = 0
        self.done = 0
        self.cb_type = 0

        IF DEBUG:
            self.loop._debug_cb_handles_total += 1
            self.loop._debug_cb_handles_count += 1

    IF DEBUG:
        def __dealloc__(self):
            self.loop._debug_cb_handles_count -= 1
            if self.done == 0 and self.cancelled == 0:
                raise RuntimeError('Active Handle is deallacating')

    @staticmethod
    cdef new(Loop loop, object callback, object args):
        cdef Handle handle
        handle = Handle.__new__(Handle)

        handle.loop = loop
        handle.cb_type = 1

        handle.arg1 = callback
        handle.arg2 = args

        return handle

    @staticmethod
    cdef new_meth(Loop loop, method_t *callback, object ctx):
        cdef Handle handle
        handle = Handle.__new__(Handle)

        handle.loop = loop
        handle.cb_type = 2

        handle.callback = <void*> callback
        handle.arg1 = ctx

        return handle

    @staticmethod
    cdef new_meth1(Loop loop, method1_t *callback,
                   object ctx, object arg):

        cdef Handle handle
        handle = Handle.__new__(Handle)

        handle.loop = loop
        handle.cb_type = 3

        handle.callback = <void*> callback
        handle.arg1 = ctx
        handle.arg2 = arg

        return handle

    @staticmethod
    cdef new_meth2(Loop loop, method2_t *callback,
                   object ctx, object arg1, object arg2):

        cdef Handle handle
        handle = Handle.__new__(Handle)

        handle.loop = loop
        handle.cb_type = 4

        handle.callback = <void*> callback
        handle.arg1 = ctx
        handle.arg2 = arg1
        handle.arg3 = arg2

        return handle

    def __init__(self):
        raise TypeError(
            '{} is not supposed to be instantiated from Python'.format(
                self.__class__.__name__))

    cdef _run(self):
        cdef:
            int cb_type
            void *callback

        if self.cancelled == 1 or self.done == 1:
            return

        cb_type = self.cb_type
        self.cb_type = 0

        callback = self.callback

        arg1 = self.arg1
        arg2 = self.arg2
        arg3 = self.arg3
        self.arg1 = self.arg2 = self.arg3 = None

        self.done = 1
        try:
            self.loop._executing_py_code = 1
            try:
                if cb_type == 1:
                    if arg2 is None:
                        arg1()
                    else:
                        arg1(*arg2)
                elif cb_type == 2:
                    ((<method_t*>callback)[0])(arg1)
                elif cb_type == 3:
                    ((<method1_t*>callback)[0])(arg1, arg2)
                elif cb_type == 4:
                    ((<method2_t*>callback)[0])(arg1, arg2, arg3)
                else:
                    raise RuntimeError('invalid Handle.cb_type: {}'.format(
                        cb_type))
            finally:
                self.loop._executing_py_code = 0
        except Exception as ex:
            msg = 'Exception in callback'
            if cb_type == 1:
                msg = 'Exception in callback {}'.format(arg1)

            self.loop.call_exception_handler({
                'message': msg,
                'exception': ex
            })


    cdef _cancel(self):
        self.cancelled = 1
        self.cb_type = 0
        self.arg1 = self.arg2 = self.arg3 = None

    # Public API

    def cancel(self):
        self._cancel()


@cython.internal
@cython.no_gc_clear
@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class TimerHandle:
    def __cinit__(self, Loop loop, object callback, object args,
                  uint64_t delay):

        self.loop = loop
        self.callback = callback
        self.args = args
        self.closed = 0

        self.timer = UVTimer.new(
            loop, <method_t*>&self._run, self, delay)

        self.timer.start()

        # Only add to loop._timers when `self.timer` is successfully created
        loop._timers.add(self)

        IF DEBUG:
            self.loop._debug_cb_timer_handles_total += 1
            self.loop._debug_cb_timer_handles_count += 1

    IF DEBUG:
        def __dealloc__(self):
            self.loop._debug_cb_timer_handles_count -= 1
            if self.closed == 0:
                raise RuntimeError('open TimerHandle is deallacating')

    cdef _cancel(self):
        if self.closed == 1:
            return
        self.closed = 1

        self.timer._close()
        self.timer = None  # let it die asap

        self.callback = None
        self.args = None

        self.loop._timers.remove(self)

    cdef _run(self):
        if self.closed == 1:
            return

        callback = self.callback
        args = self.args
        self._cancel()

        try:
            self.loop._executing_py_code = 1
            try:
                if args is not None:
                    callback(*args)
                else:
                    callback()
            finally:
                self.loop._executing_py_code = 0
        except Exception as ex:
            self.loop.call_exception_handler({
                'message': 'Exception in callback {}'.format(callback),
                'exception': ex
            })

    # Public API

    def cancel(self):
        self._cancel()
