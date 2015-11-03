# cython: language_level=3


from libc.stdint cimport uint64_t

from . cimport uv
from .loop cimport Loop


cdef class Timer:
    cdef:
        uv.uv_timer_t *handle
        object callback
        int running
        uint64_t timeout
        Loop loop

    cdef void stop(self)
    cdef void start(self)
