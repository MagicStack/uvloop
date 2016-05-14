cdef class Server:
    def __cinit__(self, Loop loop):
        self._loop = loop
        self._servers = []
        self._waiters = []
        self._active_count = 0

    cdef _add_server(self, UVStreamServer srv):
        self._servers.append(srv)

    cdef _wakeup(self):
        cdef list waiters

        waiters = self._waiters
        self._waiters = None
        for waiter in waiters:
            if not waiter.done():
                waiter.set_result(waiter)

    cdef _attach(self):
        assert self._servers is not None
        self._active_count += 1

    cdef _detach(self):
        assert self._active_count > 0
        self._active_count -= 1
        if self._active_count == 0 and self._servers is None:
            self._wakeup()

    # Public API

    def __repr__(self):
        return '<%s sockets=%r>' % (self.__class__.__name__, self.sockets)

    async def wait_closed(self):
        if self._servers is None or self._waiters is None:
            return
        waiter = self._loop._new_future()
        self._waiters.append(waiter)
        await waiter

    def close(self):
        if self._servers is None:
            return

        cdef list servers = self._servers
        self._servers = None

        for server in servers:
            (<UVStreamServer>server)._close()

        if self._active_count == 0:
            self._wakeup()

    property sockets:
        def __get__(self):
            cdef list sockets = []

            for server in self._servers:
                sockets.append(
                    (<UVStreamServer>server)._get_socket()
                )

            return sockets
