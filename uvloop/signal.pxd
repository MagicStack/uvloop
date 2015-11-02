# cython: language_level=3


from . cimport uv


cdef class Signal:
    cdef:
        uv.uv_signal_t *handle
        object callback
        int running
        int signum

    cdef stop(self)
    cdef start(self)
