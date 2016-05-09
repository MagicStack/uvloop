@cython.no_gc_clear
cdef class UVStreamServer(UVSocketHandle):

    def __cinit__(self):
        self.opened = 0
        self._server = None
        self.ssl = None
        self.protocol_factory = None

    cdef inline _init(self, Loop loop, object protocol_factory,
                      Server server, object ssl):

        if ssl is not None and not isinstance(ssl, ssl_SSLContext):
            raise TypeError(
                'ssl is expected to be None or an instance of '
                'ssl.SSLContext, got {!r}'.format(ssl))
        self.ssl = ssl

        self._start_init(loop)
        self.protocol_factory = protocol_factory
        self._server = server

    cdef inline listen(self, int backlog):
        cdef int err
        self._ensure_alive()

        if self.protocol_factory is None:
            raise RuntimeError('unable to listen(); no protocol_factory')

        if self.opened != 1:
            raise RuntimeError('unopened TCPServer')

        err = uv.uv_listen(<uv.uv_stream_t*> self._handle,
                           backlog,
                           __uv_streamserver_on_listen)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    cdef inline _on_listen(self):
        cdef UVStream slient

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

    cdef _fatal_error(self, exc, throw, reason=None):
        # Overload UVHandle._fatal_error

        self._close()

        if not isinstance(exc, (BrokenPipeError,
                                ConnectionResetError,
                                ConnectionAbortedError)):

            if throw or self._loop is None:
                raise exc

            msg = 'Fatal error on server {}'.format(
                    self.__class__.__name__)
            if reason is not None:
                msg = '{} ({})'.format(msg, reason)

            self._loop.call_exception_handler({
                'message': msg,
                'exception': exc,
            })

    cdef inline _mark_as_open(self):
        self.opened = 1

    cdef UVStream _make_new_transport(self, object protocol, object waiter):
        raise NotImplementedError

    def __on_ssl_connected(self, transport, fut):
        exc = fut.exception()
        if exc is not None:
            transport._force_close(exc)


cdef void __uv_streamserver_on_listen(uv.uv_stream_t* handle,
                                      int status) with gil:

    # callback for uv_listen

    if __ensure_handle_data(<uv.uv_handle_t*>handle,
                            "UVStream listen callback") == 0:
        return

    cdef:
        UVStreamServer stream = <UVStreamServer> handle.data

    if status < 0:
        IF DEBUG:
            stream._loop._debug_stream_listen_errors_total += 1

        exc = convert_error(status)
        stream._fatal_error(exc, False,
            "error status in uv_stream_t.listen callback")
        return

    try:
        stream._on_listen()
    except BaseException as exc:
        stream._error(exc, False)
