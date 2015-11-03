# cython: language_level=3


from . cimport uv
from .loop cimport Loop


cdef class Signal:
    cdef:
        uv.uv_signal_t *handle
        object callback
        int running
        int signum
        Loop loop

    cdef void stop(self)
    cdef void start(self)
