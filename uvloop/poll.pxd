cdef class UVPoll(UVHandle):
    cdef:
        int fd
        object reading_handle
        object writing_handle

    cdef inline _poll_start(self, int flags)
    cdef inline _poll_stop(self)

    cdef int is_active(self)

    cdef start_reading(self, object callback)
    cdef start_writing(self, object callback)
    cdef stop_reading(self)
    cdef stop_writing(self)
    cdef stop(self)
