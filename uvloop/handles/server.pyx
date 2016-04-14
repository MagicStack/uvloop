@cython.no_gc_clear
cdef class UVStreamServer(UVStream):

    cdef _init(self, Loop loop, object protocol_factory, Server server,
               object ssl):

        if ssl is not None and not isinstance(ssl, ssl_SSLContext):
            raise TypeError(
                'ssl is expected to be None or an instance of '
                'ssl.SSLContext, got {!r}'.format(ssl))
        self.ssl = ssl

        self._start_init(loop)
        self.protocol_factory = protocol_factory
        self._server = server
        self.opened = 0

    cdef listen(self, int backlog=100):
        if self.protocol_factory is None:
            raise RuntimeError('unable to listen(); no protocol_factory')

        if self.opened != 1:
            raise RuntimeError('unopened UVTCPServer')

        self._listen(backlog)

    cdef _on_listen(self):
        # Implementation for UVStream._on_listen

        protocol = self.protocol_factory()

        if self.ssl is None:
            client = self._make_new_transport(protocol, None)

        else:
            waiter = self._loop._new_future()

            ssl_protocol = aio_SSLProtocol(
                self._loop, protocol, self.ssl,
                waiter,
                True,  # server_side
                None)  # server_hostname

            client = self._make_new_transport(ssl_protocol, None)

            waiter.add_done_callback(
                ft_partial(self.__on_ssl_connected, client))

        client._accept(<UVStream>self)

    cdef inline _mark_as_open(self):
        self.opened = 1

    cdef UVTransport _make_new_transport(self, object protocol, object waiter):
        raise NotImplementedError

    def __on_ssl_connected(self, transport, fut):
        exc = fut.exception()
        if exc is not None:
            transport._force_close(exc)
