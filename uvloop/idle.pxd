cdef class Idle(BaseHandle):
    cdef:
        object callback
        int running
        Loop loop

    cdef stop(self)
    cdef start(self)
