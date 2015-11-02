# cython: language_level=3


from . cimport uv

from .async_ cimport Async
from .idle cimport Idle
from .signal cimport Signal

from libc.stdint cimport uint64_t


cdef class Loop:
    cdef:
        uv.uv_loop_t *loop
        int closed
        int _debug

        Async handler_async
        Idle handler_idle
        Signal handler_sigint

        object last_error
        object callbacks
        object partial
        object _default_task_constructor

        cdef object __weakref__

    cdef _run(self, uv.uv_run_mode)
    cdef _close(self)
    cdef _stop(self)
    cdef uint64_t _time(self)

    cdef _call_soon(self, object callback)
    cdef _call_later(self, uint64_t delay, object callback)
