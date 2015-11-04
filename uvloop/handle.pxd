cdef class BaseHandle:
    cdef:
        uv.uv_handle_t *handle
        int closed

    cdef close(self)

    # Handle exceptions in subclasses
    cdef void on_close(self)
