cdef class UVTCP(UVStream):
    cdef:
        int opened

    cdef inline ensure_open(self)

    cdef enable_nodelay(self)
    cdef disable_nodelay(self)

    cdef open(self, int sockfd)
