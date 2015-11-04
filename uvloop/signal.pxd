cdef class Signal(BaseHandle):
    cdef:
        object callback
        int running
        int signum
        Loop loop

    cdef stop(self)
    cdef start(self)
