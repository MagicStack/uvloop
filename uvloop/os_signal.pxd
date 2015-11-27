from libc.signal cimport sighandler_t


cdef class SignalsStack:
    cdef:
        sighandler_t[MAX_SIG] signals
        bint saved

    cdef save(self)
    cdef restore(self)
