cdef class UVAsync(UVHandle):
    cdef:
        object callback

    cdef send(self)
