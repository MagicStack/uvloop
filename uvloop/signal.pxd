cdef class Signal(BaseHandle):
    cdef:
        object callback
        int running
        int signum

    cdef stop(self)
    cdef start(self)
