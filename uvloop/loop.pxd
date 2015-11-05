# cython: language_level=3


from . cimport uv

from libc.stdint cimport uint64_t


cdef class UVHandle
cdef class UVAsync(UVHandle)
cdef class UVTimer(UVHandle)
cdef class UVSignal(UVHandle)
cdef class UVIdle(UVHandle)


cdef class Loop:
    cdef:
        uv.uv_loop_t *loop
        int _closed
        int _debug
        long _thread_id
        int _running

        object _ready
        int _ready_len
        object _timers

        UVAsync handler_async
        UVIdle handler_idle
        UVSignal handler_sigint

        object _last_error

        cdef object __weakref__

    cdef _run(self, uv.uv_run_mode)
    cdef _close(self)
    cdef _stop(self)
    cdef uint64_t _time(self)

    cdef _call_soon(self, object callback)
    cdef _call_later(self, uint64_t delay, object callback)

    cdef void _handle_uvcb_exception(self, object ex)
    cdef _handle_uv_error(self, int err)

    cdef _check_closed(self)
    cdef _check_thread(self)


include "handle.pxd"
include "async_.pxd"
include "idle.pxd"
include "timer.pxd"
include "signal.pxd"

include "stream.pxd"
include "tcp.pxd"
