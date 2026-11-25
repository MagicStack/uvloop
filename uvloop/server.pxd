cdef class Server:
    cdef:
        list _servers
        list _waiters
        int _active_count
        object _clients
        Loop _loop
        bint _serving
        object _serving_forever_fut
        object __weakref__

    cdef _add_server(self, UVStreamServer srv)
    cdef _start_serving(self)
    cdef _wakeup(self)

    cdef _attach(self, UVBaseTransport transport)
    cdef _detach(self, UVBaseTransport transport)

    cdef _ref(self)
    cdef _unref(self)
