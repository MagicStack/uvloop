# cython: language_level=3


from libc.stdint cimport uint64_t

from . cimport uv


cdef class Timer:
    cdef:
        uv.uv_timer_t *handle
        object callback
        int running
        uint64_t timeout

    cdef stop(self)
    cdef start(self)
