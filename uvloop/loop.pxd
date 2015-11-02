# cython: language_level=3


from . cimport uv

from .idle cimport Idle
from .signal cimport Signal


cdef class Loop:
    cdef:
        uv.uv_loop_t *loop
        int closed

        Idle handler_idle
        Signal handler_sigint

        object last_error

    cdef _run(self, uv.uv_run_mode)

    cpdef close(self)
