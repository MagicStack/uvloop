cdef class UVFSEvent(UVHandle):
    cdef:
        object callback

    cdef _init(self, Loop loop, char* path, object callback,
               int flags)

    cdef _close(self)
    #cdef start(self)
    #cdef get_when(self)

    @staticmethod
    cdef UVFSEvent new(Loop loop, char* path, object callback,
               int flags)