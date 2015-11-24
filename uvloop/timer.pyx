@cython.final
@cython.internal
cdef class UVTimer(UVHandle):
    def __cinit__(self, Loop loop, object callback, uint64_t timeout):
        cdef int err

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_timer_t))
        if self._handle is NULL:
            raise MemoryError()

        self._handle.data = <void*> self

        err = uv.uv_timer_init(loop.loop, <uv.uv_timer_t*>self._handle)
        if err < 0:
            raise convert_error(err)

        self.callback = callback
        self.running = 0
        self.timeout = timeout

    cdef stop(self):
        cdef int err

        self._ensure_alive()

        if self.running == 1:
            err = uv.uv_timer_stop(<uv.uv_timer_t*>self._handle)
            self.running = 0
            if err < 0:
                raise convert_error(err)

    cdef start(self):
        cdef int err

        self._ensure_alive()

        if self.running == 0:
            err = uv.uv_timer_start(<uv.uv_timer_t*>self._handle,
                                    __uvtimer_callback,
                                    self.timeout, 0)
            if err < 0:
                raise convert_error(err)
            self.running = 1


cdef void __uvtimer_callback(uv.uv_timer_t* handle) with gil:
    cdef UVTimer timer = <UVTimer> handle.data
    timer.running = 0
    try:
        timer.callback()
    except BaseException as ex:
        timer._loop._handle_uvcb_exception(ex)
