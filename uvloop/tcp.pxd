cdef class UVTCP(UVStream):
    cdef enable_nodelay(self)
    cdef disable_nodelay(self)
