from . cimport uv
from .loop cimport Loop
from .handle cimport Handle


cdef class Signal(Handle):
    cdef:
        object callback
        int running
        int signum
        Loop loop

    cdef stop(self)
    cdef start(self)
