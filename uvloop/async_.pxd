# cython: language_level=3


from . cimport uv
from .loop cimport Loop
from .handle cimport Handle


cdef class Async(Handle):
    cdef:
        object callback
        Loop loop

    cdef send(self)
