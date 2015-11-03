# cython: language_level=3


from . cimport uv
from .loop cimport Loop
from .handle cimport Handle


cdef class Idle(Handle):
    cdef:
        object callback
        int running
        Loop loop

    cdef stop(self)
    cdef start(self)
