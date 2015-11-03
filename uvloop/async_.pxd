# cython: language_level=3


from . cimport uv


cdef class Async:
    cdef:
        uv.uv_async_t *handle
        object callback

    cdef void send(self)
