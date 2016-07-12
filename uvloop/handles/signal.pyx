@cython.no_gc_clear
cdef class UVSignal(UVHandle):
    cdef _init(self, Loop loop, Handle h, int signum):
        cdef int err

        self._start_init(loop)

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_signal_t))
        if self._handle is NULL:
            self._abort_init()
            raise MemoryError()

        err = uv.uv_signal_init(self._loop.uvloop,
                                <uv.uv_signal_t *>self._handle)
        if err < 0:
            self._abort_init()
            raise convert_error(err)

        self._finish_init()

        self.h = h
        self.running = 0
        self.signum = signum

    cdef stop(self):
        cdef int err

        if not self._is_alive():
            self.running = 0
            return

        if self.running == 1:
            err = uv.uv_signal_stop(<uv.uv_signal_t *>self._handle)
            self.running = 0
            if err < 0:
                exc = convert_error(err)
                self._fatal_error(exc, True)
                return

    cdef start(self):
        cdef int err

        self._ensure_alive()

        if self.running == 0:
            err = uv.uv_signal_start(<uv.uv_signal_t *>self._handle,
                                     __uvsignal_callback,
                                     self.signum)
            if err < 0:
                exc = convert_error(err)
                self._fatal_error(exc, True)
                return
            self.running = 1

    @staticmethod
    cdef UVSignal new(Loop loop, Handle h, int signum):

        cdef UVSignal handle
        handle = UVSignal.__new__(UVSignal)
        handle._init(loop, h, signum)
        return handle


cdef void __uvsignal_callback(uv.uv_signal_t* handle, int signum) with gil:
    if __ensure_handle_data(<uv.uv_handle_t*>handle, "UVSignal callback") == 0:
        return

    cdef:
        UVSignal sig = <UVSignal> handle.data
        Handle h = sig.h
    sig.running = 0
    try:
        h._run()
    except BaseException as ex:
        sig._error(ex, False)
