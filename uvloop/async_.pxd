cdef class Async(BaseHandle):
    cdef:
        object callback

    cdef send(self)
