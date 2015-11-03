from . cimport uv
from .loop cimport Loop
from .handle cimport Handle

from cpython.mem cimport PyMem_Malloc, PyMem_Free


cdef class Signal(Handle):
    def __cinit__(self, Loop loop, object callback, int signum):
        cdef int err

        self.handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_signal_t))
        if self.handle is NULL:
            raise MemoryError()

        self.handle.data = <void*> self

        err = uv.uv_signal_init(loop.loop, <uv.uv_signal_t *>self.handle)
        if err < 0:
            loop._handle_uv_error(err)

        self.callback = callback
        self.running = 0
        self.signum = signum
        self.loop = loop

    cdef stop(self):
        cdef int err

        if self.running == 1:
            err = uv.uv_signal_stop(<uv.uv_signal_t *>self.handle)
            if err < 0:
                self.loop._handle_uv_error(err)
            self.running = 0

    cdef start(self):
        cdef int err

        if self.running == 0:
            err = uv.uv_signal_start(<uv.uv_signal_t *>self.handle,
                                     cb_signal_callback,
                                     self.signum)
            if err < 0:
                self.loop._handle_uv_error(err)
            self.running = 1


cdef void cb_signal_callback(uv.uv_signal_t* handle, int signum):
    cdef Signal sig = <Signal> handle.data
    sig.running = 0
    try:
        sig.callback()
    except BaseException as ex:
        sig.loop._handle_uvcb_exception(ex)
