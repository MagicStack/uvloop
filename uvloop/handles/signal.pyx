@cython.final
@cython.internal
@cython.no_gc_clear
cdef class UVSignal(UVHandle):
    cdef _init(self, method_t* callback, object ctx, int signum):
        cdef int err

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_signal_t))
        if self._handle is NULL:
            self._close()
            raise MemoryError()

        err = uv.uv_signal_init(self._loop.uvloop,
                                <uv.uv_signal_t *>self._handle)
        if err < 0:
            __cleanup_handle_after_init(<UVHandle>self)
            raise convert_error(err)

        self._handle.data = <void*> self
        self.callback = callback
        self.ctx = ctx
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
                self._close()
                raise convert_error(err)

    cdef start(self):
        cdef int err

        self._ensure_alive()

        if self.running == 0:
            err = uv.uv_signal_start(<uv.uv_signal_t *>self._handle,
                                     __uvsignal_callback,
                                     self.signum)
            if err < 0:
                self._close()
                raise convert_error(err)
            self.running = 1

    @staticmethod
    cdef UVSignal new(Loop loop, method_t* callback, object ctx,
                      int signum):

        cdef UVSignal handle
        handle = UVSignal.__new__(UVSignal)
        handle._set_loop(loop)
        handle._init(callback, ctx, signum)
        return handle


cdef void __uvsignal_callback(uv.uv_signal_t* handle, int signum) with gil:
    if __ensure_handle_data(<uv.uv_handle_t*>handle, "UVSignal callback") == 0:
        return

    cdef:
        UVSignal sig = <UVSignal> handle.data
        method_t cb = sig.callback[0] # deref
    sig.running = 0
    try:
        cb(sig.ctx)
    except BaseException as ex:
        sig._loop._handle_uvcb_exception(ex)
