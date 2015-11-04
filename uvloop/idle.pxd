cdef class Idle(BaseHandle):
    cdef:
        object callback
        int running

    cdef stop(self)
    cdef start(self)
