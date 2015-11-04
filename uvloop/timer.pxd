# cython: language_level=3


from libc.stdint cimport uint64_t

from . cimport uv
from .loop cimport Loop
from .handle cimport Handle


cdef class Timer(Handle):
    cdef:
        object callback
        object on_close_callback
        int running
        uint64_t timeout
        Loop loop

    cdef stop(self)
    cdef start(self)
