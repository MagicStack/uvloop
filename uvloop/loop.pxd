# cython: language_level=3


from . cimport uv

from .async_ cimport Async
from .idle cimport Idle
from .signal cimport Signal

from libc.stdint cimport uint64_t


cdef class Loop:
    cdef:
        uv.uv_loop_t *loop
        int _closed
        int _debug
        long _thread_id
        int _running

        object _ready
        int _ready_len

        Async handler_async
        Idle handler_idle
        Signal handler_sigint

        object _last_error

        object _make_partial
        object _asyncio
        object _asyncio_Task

        cdef object __weakref__

    cdef _run(self, uv.uv_run_mode)
    cdef _close(self)
    cdef _stop(self)
    cdef uint64_t _time(self)

    cdef _call_soon(self, object callback)
    cdef _call_later(self, uint64_t delay, object callback)

    cdef _handle_uvcb_exception(self, object ex)

    cdef _check_closed(self)
    cdef _check_thread(self)
