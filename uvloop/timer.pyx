cdef class UVTimer(UVHandle):
    def __cinit__(self, Loop loop, object callback, uint64_t timeout,
                  object on_close_callback):
        cdef int err

        self.handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_timer_t))
        if self.handle is NULL:
            raise MemoryError()

        self.handle.data = <void*> self

        err = uv.uv_timer_init(loop.loop, <uv.uv_timer_t*>self.handle)
        if err < 0:
            raise UVError.from_error(err)

        self.callback = callback
        self.on_close_callback = on_close_callback
        self.running = 0
        self.timeout = timeout

    cdef stop(self):
        cdef int err

        self.ensure_alive()

        if self.running == 1:
            err = uv.uv_timer_stop(<uv.uv_timer_t*>self.handle)
            self.running = 0
            if err < 0:
                raise UVError.from_error(err)

    cdef start(self):
        cdef int err

        self.ensure_alive()

        if self.running == 0:
            err = uv.uv_timer_start(<uv.uv_timer_t*>self.handle,
                                    cb_timer_callback,
                                    self.timeout, 0)
            if err < 0:
                raise UVError.from_error(err)
            self.running = 1

    cdef on_close(self):
        UVHandle.on_close(self)
        self.on_close_callback()


cdef void cb_timer_callback(uv.uv_timer_t* handle):
    cdef UVTimer timer = <UVTimer> handle.data
    timer.running = 0
    try:
        timer.callback()
    except BaseException as ex:
        timer.loop._handle_uvcb_exception(ex)
