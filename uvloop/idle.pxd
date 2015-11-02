# cython: language_level=3


from . cimport uv


cdef class Idle:
    cdef:
        uv.uv_idle_t *handle
        object callback
        int running

    cdef stop(self)
    cdef start(self)
