@cython.final
@cython.internal
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

        object          callback
        UVStream        stream

        bint            closed

    cdef close(self):
        if self.closed:
            return

        self.closed = 1
        self.callback = None
        PyBuffer_Release(&self.py_buf)  # void
        self.req.data = NULL
        Py_DECREF(self)
        IF not DEBUG:
            self.stream = None

    @staticmethod
    cdef _StreamWriteContext new(UVStream stream, object data, object callback):
        cdef _StreamWriteContext ctx
        ctx = _StreamWriteContext.__new__(_StreamWriteContext)

        ctx.req.data = <void*> ctx
        Py_INCREF(ctx)

        PyObject_GetBuffer(data, &ctx.py_buf, PyBUF_SIMPLE)
        ctx.uv_buf = uv.uv_buf_init(<char*>ctx.py_buf.buf, ctx.py_buf.len)
        ctx.stream = stream
        ctx.callback = callback

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


@cython.internal
@cython.no_gc_clear
cdef class UVStream(UVHandle):
    def __cinit__(self):
        self.__reading = 0
        self.__cached_socket = None

    cdef _shutdown(self):
        cdef int err
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

    cdef _start_reading(self):
        cdef int err
        self._ensure_alive()

        if self.__reading:
            raise RuntimeError('Already reading')

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

        if not self.__reading:
            raise RuntimeError('Already stopped')
        self.__reading_stopped()

        self._ensure_alive()

        err = uv.uv_read_stop(<uv.uv_stream_t*>self._handle)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    cdef bint _is_readable(self):
        return uv.uv_is_readable(<uv.uv_stream_t*>self._handle)

    cdef bint _is_writable(self):
        return uv.uv_is_writable(<uv.uv_stream_t*>self._handle)

    cdef _write(self, object data, object callback):
        cdef:
            int err
            _StreamWriteContext ctx

        self._ensure_alive()

        ctx = _StreamWriteContext.new(self, data, callback)

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

        self.__cached_socket = socket_fromfd(self._fileno(),
                                            buf.ss_family,
                                            uv.SOCK_STREAM)

        return self.__cached_socket

    cdef _close(self):
        self.__reading_stopped()
        UVHandle._close(self)
        if self.__cached_socket is not None:
            self.__cached_socket.close()
            self.__cached_socket = None

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


cdef void __uv_stream_on_shutdown(uv.uv_shutdown_t* req,
                                  int status) with gil:

    # callback for uv_shutdown

    if req.data is NULL:
        aio_logger.error(
            'UVStream.shutdown callback called with NULL req.data, status=%r',
            status)
        return

    cdef UVStream stream = <UVStream> req.data

    if status < 0:
        exc = convert_error(status)
        stream._fatal_error(exc, False)
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
        exc = convert_error(status)
        stream._fatal_error(exc, False)
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

    __loop_free_buffer(loop)

    if nread == uv.UV_EOF:
        # From libuv docs:
        #     The callee is responsible for stopping closing the stream
        #     when an error happens by calling uv_read_stop() or uv_close().
        #     Trying to read from the stream again is undefined.
        try:
            sc._stop_reading()
            sc._on_eof()
        except BaseException as ex:
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

        exc = convert_error(nread)
        sc._fatal_error(exc, False)
        return

    try:
        sc._on_read(loop._recv_buffer[:nread])
    except BaseException as exc:
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
        object callback = ctx.callback

    ctx.close()

    if status < 0:
        exc = convert_error(status)
        stream._fatal_error(exc, False)
        return

    try:
        stream._on_write()
        if callback is not None:
            callback()
    except BaseException as exc:
        stream._error(exc, False)
