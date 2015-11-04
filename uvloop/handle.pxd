# cython: language_level=3


from . cimport uv


cdef class Handle:
    cdef:
        uv.uv_handle_t *handle
        int closed

    cdef close(self)

    # Handle exceptions in subclasses
    cdef void on_close(self)
