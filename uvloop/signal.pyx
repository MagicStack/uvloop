@cython.final
@cython.internal
cdef class UVSignal(UVHandle):
    def __cinit__(self, Loop loop, object callback, int signum):
        cdef int err

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_signal_t))
        if self._handle is NULL:
            raise MemoryError()

        self._handle.data = <void*> self

        err = uv.uv_signal_init(loop.uvloop, <uv.uv_signal_t *>self._handle)
        if err < 0:
            raise convert_error(err)

        self.callback = callback
        self.running = 0
        self.signum = signum

    cdef stop(self):
        cdef int err

        self._ensure_alive()

        if self.running == 1:
            err = uv.uv_signal_stop(<uv.uv_signal_t *>self._handle)
            self.running = 0
            if err < 0:
                raise convert_error(err)

    cdef start(self):
        cdef int err

        self._ensure_alive()

        if self.running == 0:
            err = uv.uv_signal_start(<uv.uv_signal_t *>self._handle,
                                     __uvsignal_callback,
                                     self.signum)
            if err < 0:
                raise convert_error(err)
            self.running = 1


cdef void __uvsignal_callback(uv.uv_signal_t* handle, int signum) with gil:
    cdef UVSignal sig = <UVSignal> handle.data
    sig.running = 0
    try:
        sig.callback()
    except BaseException as ex:
        sig._loop._handle_uvcb_exception(ex)
