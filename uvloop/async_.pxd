cdef class Async(BaseHandle):
    cdef:
        object callback
        Loop loop

    cdef send(self)
