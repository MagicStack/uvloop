cdef class Timer(BaseHandle):
    cdef:
        object callback
        object on_close_callback
        int running
        uint64_t timeout
        Loop loop

    cdef stop(self)
    cdef start(self)
