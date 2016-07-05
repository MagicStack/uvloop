cdef class UVAsync(UVHandle):
    cdef:
        uv.uv_async_t _handle_data
        method_t callback
        object ctx

    cdef _init(self, Loop loop, method_t callback, object ctx)

    cdef send(self)

    @staticmethod
    cdef UVAsync new(Loop loop, method_t callback, object ctx)
