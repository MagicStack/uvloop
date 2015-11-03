# cython: language_level=3


from . cimport uv
from .loop cimport Loop


cdef class Idle:
    cdef:
        uv.uv_idle_t *handle
        object callback
        int running
        Loop loop

    cdef void stop(self)
    cdef void start(self)
