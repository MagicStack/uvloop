cdef class Server:
    cdef:
        Loop loop
        int active_count
        int closed

        list sockets
        list waiters

    def __cinit__(self, Loop loop not None, list sockets not None):
        self.loop = loop
        self.sockets = sockets
        self.waiters = []
        self.active_count = 0
        self.closed = 0

    cdef _attach(self):
        if self.closed is 1:
            raise RuntimeError('cannot _attach() after close()')

        self.active_count += 1

    cdef _detach(self):
        if self.active_count == 0:
            raise RuntimeError('too many _detach() calls on Server')

        self.active_count -= 1

        if self.active_count == 0 and self.closed == 1:
            self._wakeup()

    cdef _wakeup(self):
        if self.closed is 1:
            raise RuntimeError('cannot _wakeup() after close()')

        cdef list waiters = self.waiters
        self.waiters = None
        for waiter in waiters:
            if not waiter.done():
                waiter.set_result(waiter)

    # Public API

    def __repr__(self):
        return '<%s sockets=%r closed=%r>' % (
            self.__class__.__name__,
            self.sockets,
            bool(self.closed))

    def close(self):
        if self.closed == 1:
            return
        self.closed = 1

        cdef list sockets = self.sockets
        self.sockets = None

        for sock in sockets:
            self.loop._stop_serving(sock)

        if self.active_count == 0:
            self._wakeup()

    async def wait_closed(self):
        if self.sockets is None or self.waiters is None:
            return

        waiter = aio_Future(loop=self.loop)
        self.waiters.append(waiter)
        await waiter
