# cython: language_level=3


from . cimport uv

from .async_ cimport Async
from .idle cimport Idle
from .signal cimport Signal


cdef class Loop:
    cdef:
        uv.uv_loop_t *loop
        int closed

        Async handler_async
        Idle handler_idle
        Signal handler_sigint

        object last_error
        object callbacks

    cdef _run(self, uv.uv_run_mode)
    cdef _close(self)
    cdef _time(self)

    cdef _call_soon(self, callback, args)
