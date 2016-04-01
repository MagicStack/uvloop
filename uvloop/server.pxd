cdef class Server:
    cdef:
        list _servers
        list _waiters
        int _active_count
        Loop _loop

    cdef _add_server(self, UVStreamServer srv)
    cdef _wakeup(self)

    cdef _attach(self)
    cdef _detach(self)
