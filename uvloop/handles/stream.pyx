@cython.no_gc_clear
@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class _StreamWriteContext:
    # used to hold additional write request information for uv_write

    cdef:
        uv.uv_write_t   req     # uv_cancel doesn't support uv_write_t,
                                # hence we don't use UVRequest here,
                                # and just work with the request directly.
                                # libuv will initialize `req`.

        uv.uv_buf_t     uv_buf
        Py_buffer       py_buf

        UVStream        stream

        bint            closed

    cdef close(self):
        if self.closed:
            return

        self.closed = 1
        PyBuffer_Release(&self.py_buf)  # void
        self.req.data = NULL
        Py_DECREF(self)
        IF not DEBUG:
            self.stream = None

    @staticmethod
    cdef _StreamWriteContext new(UVStream stream, object data):
        cdef _StreamWriteContext ctx
        ctx = _StreamWriteContext.__new__(_StreamWriteContext)

        ctx.req.data = <void*> ctx
        Py_INCREF(ctx)

        PyObject_GetBuffer(data, &ctx.py_buf, PyBUF_SIMPLE)
        ctx.uv_buf = uv.uv_buf_init(<char*>ctx.py_buf.buf, ctx.py_buf.len)
        ctx.stream = stream

        ctx.closed = 0

        IF DEBUG:
            stream._loop._debug_stream_write_ctx_total += 1
            stream._loop._debug_stream_write_ctx_cnt += 1

        return ctx

    IF DEBUG:
        def __dealloc__(self):
            if not self.closed:
                raise RuntimeError(
                    'open _StreamWriteContext is being deallocated')

            IF DEBUG:
                self.stream._loop._debug_stream_write_ctx_cnt -= 1

            self.stream = None


@cython.no_gc_clear
cdef class UVStream(UVHandle):

    def __cinit__(self):
        self.__shutting_down = 0
        self.__reading = 0
        self.__cached_socket = None

    cdef _shutdown(self):
        cdef int err

        if self.__shutting_down:
            IF DEBUG:
                raise RuntimeError('UVStream: second shutdown call')
            return
        self.__shutting_down = 1

        self._ensure_alive()

        self._shutdown_req.data = <void*> self
        err = uv.uv_shutdown(&self._shutdown_req,
                             <uv.uv_stream_t*> self._handle,
                             __uv_stream_on_shutdown)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    cdef _listen(self, int backlog):
        cdef int err
        self._ensure_alive()

        err = uv.uv_listen(<uv.uv_stream_t*> self._handle,
                           backlog,
                           __uv_stream_on_listen)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    cdef _accept(self, UVStream server):
        cdef int err
        self._ensure_alive()

        err = uv.uv_accept(<uv.uv_stream_t*>server._handle,
                           <uv.uv_stream_t*>self._handle)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

        self._on_accept()

    cdef bint _is_reading(self):
        return self.__reading

    cdef _start_reading(self):
        cdef int err
        self._ensure_alive()

        if self.__reading or not self._is_readable():
            return

        err = uv.uv_read_start(<uv.uv_stream_t*>self._handle,
                               __loop_alloc_buffer,
                               __uv_stream_on_read)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return
        else:
            # UVStream must live until the read callback is called
            self.__reading_started()

    cdef __reading_started(self):
        if self.__reading:
            return
        self.__reading = 1
        Py_INCREF(self)

    cdef __reading_stopped(self):
        if not self.__reading:
            return
        self.__reading = 0
        Py_DECREF(self)

    cdef _stop_reading(self):
        cdef int err

        if not self.__reading or not self._is_readable():
            return
        self.__reading_stopped()

        self._ensure_alive()

        err = uv.uv_read_stop(<uv.uv_stream_t*>self._handle)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    cdef inline bint _is_readable(self):
        return uv.uv_is_readable(<uv.uv_stream_t*>self._handle)

    cdef inline bint _is_writable(self):
        return uv.uv_is_writable(<uv.uv_stream_t*>self._handle)

    cdef _write(self, object data):
        cdef:
            int err
            _StreamWriteContext ctx

        self._ensure_alive()

        ctx = _StreamWriteContext.new(self, data)

        err = uv.uv_write(&ctx.req,
                          <uv.uv_stream_t*>self._handle,
                          &ctx.uv_buf,
                          1,
                          __uv_stream_on_write)

        if err < 0:
            # close write context
            ctx.close()

            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    cdef _fileno(self):
        cdef:
            int fd
            int err

        err = uv.uv_fileno(<uv.uv_handle_t*>self._handle, <uv.uv_os_fd_t*>&fd)
        if err < 0:
            raise convert_error(err)

        return fd

    cdef _get_socket(self):
        cdef:
            int buf_len = sizeof(system.sockaddr_storage)
            int err
            system.sockaddr_storage buf

        if self.__cached_socket is not None:
            return self.__cached_socket

        err = uv.uv_tcp_getsockname(<uv.uv_tcp_t*>self._handle,
                                    <system.sockaddr*>&buf,
                                    &buf_len)
        if err < 0:
            raise convert_error(err)

        self.__cached_socket = socket_socket(
            buf.ss_family, uv.SOCK_STREAM, 0, self._fileno())

        return self.__cached_socket

    cdef inline size_t _get_write_buffer_size(self):
        if self._handle is NULL:
            return 0
        return (<uv.uv_stream_t*>self._handle).write_queue_size

    cdef _attach_fileobj(self, file):
        # When we create a TCP/PIPE/etc connection/server based on
        # a Python file object, we need to close the file object when
        # the uv handle is closed.
        self._fileobj = file

    cdef _close(self):
        try:
            self._stop_reading()

            if self.__cached_socket is not None:
                try:
                    self.__cached_socket.detach()
                except OSError:
                    pass
                self.__cached_socket = None

            if self._fileobj is not None:
                try:
                    self._fileobj.close()
                except Exception as exc:
                    self._loop.call_exception_handler({
                        'exception': exc,
                        'transport': self,
                        'message': 'could not close attached file object {!r}'.
                            format(self._fileobj)
                    })
                finally:
                    self._fileobj = None

        finally:
            UVHandle._close(<UVHandle>self)

    # Methods to override.

    cdef _on_accept(self):
        raise NotImplementedError

    cdef _on_listen(self):
        raise NotImplementedError

    cdef _on_read(self, bytes buf):
        raise NotImplementedError

    cdef _on_eof(self):
        raise NotImplementedError

    cdef _on_write(self):
        # This method is optional, no need to raise NotImplementedError
        pass

    cdef _on_shutdown(self):
        # This method is optional, no need to raise NotImplementedError
        pass

    def __repr__(self):
        return '<{} closed={} reading={} {:#x}>'.format(
            self.__class__.__name__,
            self._closed,
            self.__reading,
            id(self))


@cython.no_gc_clear
cdef class UVStreamServer(UVStream):

    cdef _init(self, Loop loop, object protocol_factory, Server server):
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
        client = self._make_new_transport(protocol)
        client._accept(<UVStream>self)

    cdef inline _mark_as_open(self):
        self.opened = 1

    cdef UVTransport _make_new_transport(self, object protocol):
        raise NotImplementedError


cdef void __uv_stream_on_shutdown(uv.uv_shutdown_t* req,
                                  int status) with gil:

    # callback for uv_shutdown

    if req.data is NULL:
        aio_logger.error(
            'UVStream.shutdown callback called with NULL req.data, status=%r',
            status)
        return

    cdef UVStream stream = <UVStream> req.data

    if status < 0 and status != uv.UV_ECANCELED:
        # From libuv source code:
        #     The ECANCELED error code is a lie, the shutdown(2) syscall is a
        #     fait accompli at this point. Maybe we should revisit this in
        #     v0.11.  A possible reason for leaving it unchanged is that it
        #     informs the callee that the handle has been destroyed.

        IF DEBUG:
            stream._loop._debug_stream_shutdown_errors_total += 1

        exc = convert_error(status)
        stream._fatal_error(exc, False,
            "error status in uv_stream_t.shutdown callback")
        return

    try:
        stream._on_shutdown()
    except BaseException as ex:
        stream._error(ex, False)


cdef void __uv_stream_on_listen(uv.uv_stream_t* handle,
                                int status) with gil:

    # callback for uv_listen

    if __ensure_handle_data(<uv.uv_handle_t*>handle,
                            "UVStream listen callback") == 0:
        return

    cdef:
        UVStream stream = <UVStream> handle.data

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


cdef void __uv_stream_on_read(uv.uv_stream_t* stream,
                              ssize_t nread,
                              const uv.uv_buf_t* buf) with gil:

    # callback for uv_read_start

    if __ensure_handle_data(<uv.uv_handle_t*>stream,
                            "UVStream read callback") == 0:
        return

    cdef:
        UVStream sc = <UVStream>stream.data
        Loop loop = sc._loop

    # It's OK to free the buffer early, since nothing will
    # be able to touch it until this method is done.
    __loop_free_buffer(loop)

    if sc._closed:
        # The stream was closed, there is no reason to
        # do any work now.
        return

    if nread == uv.UV_EOF:
        # From libuv docs:
        #     The callee is responsible for stopping closing the stream
        #     when an error happens by calling uv_read_stop() or uv_close().
        #     Trying to read from the stream again is undefined.
        try:
            IF DEBUG:
                loop._debug_stream_read_eof_total += 1

            sc._stop_reading()
            sc._on_eof()
        except BaseException as ex:
            IF DEBUG:
                loop._debug_stream_read_eof_cb_errors_total += 1

            sc._error(ex, False)
        finally:
            return

    if nread == 0:
        # From libuv docs:
        #     nread might be 0, which does not indicate an error or EOF.
        #     This is equivalent to EAGAIN or EWOULDBLOCK under read(2).
        return

    if nread < 0:
        # From libuv docs:
        #     The callee is responsible for stopping closing the stream
        #     when an error happens by calling uv_read_stop() or uv_close().
        #     Trying to read from the stream again is undefined.
        #
        # Therefore, we're closing the stream.  Since "UVHandle._close()"
        # doesn't raise exceptions unless uvloop is built with DEBUG=1,
        # we don't need try...finally here.

        IF DEBUG:
            loop._debug_stream_read_errors_total += 1

        exc = convert_error(nread)
        sc._fatal_error(exc, False,
            "error status in uv_stream_t.read callback")
        return

    try:
        IF DEBUG:
            loop._debug_stream_read_cb_total += 1

        sc._on_read(loop._recv_buffer[:nread])
    except BaseException as exc:
        IF DEBUG:
            loop._debug_stream_read_cb_errors_total += 1

        sc._error(exc, False)


cdef void __uv_stream_on_write(uv.uv_write_t* req, int status) with gil:
    # callback for uv_write

    if req.data is NULL:
        # Shouldn't happen as:
        #    - _StreamWriteContext does an extra INCREF in its 'init()'
        #    - _StreamWriteContext holds a ref to the relevant UVStream
        aio_logger.error(
            'UVStream.write callback called with NULL req.data, status=%r',
            status)
        return

    cdef:
        _StreamWriteContext ctx = <_StreamWriteContext> req.data
        UVStream stream = ctx.stream

    ctx.close()

    if stream._closed:
        # The stream was closed, there is nothing to do.
        # Even if there is an error, like EPIPE, there
        # is no reason to report it.
        return

    if status < 0:
        IF DEBUG:
            stream._loop._debug_stream_write_errors_total += 1

        exc = convert_error(status)
        stream._fatal_error(exc, False,
            "error status in uv_stream_t.write callback")
        return

    try:
        stream._on_write()
    except BaseException as exc:
        IF DEBUG:
            stream._loop._debug_stream_write_cb_errors_total += 1

        stream._error(exc, False)
