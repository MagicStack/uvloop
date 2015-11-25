@cython.final
@cython.internal
@cython.no_gc_clear
@cython.freelist(250)
cdef class __StreamWriteContext:
    # used to hold additional write request information for uv_write

    cdef:
        uv.uv_write_t   req     # uv_cancel doesn't support uv_write_t,
                                # hence we don't use UVRequest here,
                                # and just work with the request directly.

        uv.uv_buf_t     uv_buf
        Py_buffer       py_buf

        object          callback
        UVStream        stream

        bint            closed

    cdef init(self, UVStream stream, object data, object callback):
        self.req.data = <void*> self
        Py_INCREF(self)

        PyObject_GetBuffer(data, &self.py_buf, PyBUF_SIMPLE)
        self.uv_buf = uv.uv_buf_init(<char*>self.py_buf.buf, self.py_buf.len)
        self.stream = stream
        self.callback = callback

        self.closed = 0

    cdef close(self):
        if self.closed:
            return

        self.closed = 1

        PyBuffer_Release(&self.py_buf)

        Py_DECREF(self)

    IF DEBUG:
        def __dealloc__(self):
            if not self.closed:
                raise RuntimeError(
                    'open __StreamWriteContext is being deallocated')


@cython.internal
cdef class UVStream(UVHandle):
    cdef _shutdown(self):
        cdef int err
        self._ensure_alive()

        self._shutdown_req.data = <void*> self
        err = uv.uv_shutdown(&self._shutdown_req,
                             <uv.uv_stream_t*> self._handle,
                             __uv_stream_on_shutdown)
        if err < 0:
            self._close()
            raise convert_error(err)

    cdef _listen(self, int backlog):
        cdef int err
        self._ensure_alive()

        err = uv.uv_listen(<uv.uv_stream_t*> self._handle,
                           backlog,
                           __uv_stream_on_listen)
        if err < 0:
            self._close()
            raise convert_error(err)

    cdef _accept(self, UVStream server):
        cdef int err
        self._ensure_alive()

        err = uv.uv_accept(<uv.uv_stream_t*>server._handle,
                           <uv.uv_stream_t*>self._handle)
        if err < 0:
            self._close()
            raise convert_error(err)

        self._on_accept()

    cdef _start_reading(self):
        cdef int err
        self._ensure_alive()

        err = uv.uv_read_start(<uv.uv_stream_t*>self._handle,
                               __loop_alloc_buffer,
                               __uv_stream_on_read)
        if err < 0:
            self._close()
            raise convert_error(err)

    cdef _stop_reading(self):
        cdef int err
        self._ensure_alive()

        err = uv.uv_read_stop(<uv.uv_stream_t*>self._handle)
        if err < 0:
            self._close()
            raise convert_error(err)

    cdef int _is_readable(self):
        return uv.uv_is_readable(<uv.uv_stream_t*>self._handle)

    cdef int _is_writable(self):
        return uv.uv_is_writable(<uv.uv_stream_t*>self._handle)

    cdef _write(self, object data, object callback):
        cdef:
            int err
            __StreamWriteContext ctx

        self._ensure_alive()

        ctx = __StreamWriteContext()
        ctx.init(self, data, callback)

        err = uv.uv_write(&ctx.req,
                          <uv.uv_stream_t*>self._handle,
                          &ctx.uv_buf,
                          1,
                          __uv_stream_on_write)

        if err < 0:
            ctx.close()
            self._close()
            raise convert_error(err)

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


cdef void __uv_stream_on_shutdown(uv.uv_shutdown_t* req,
                                  int status) with gil:

    # callback for uv_shutdown

    cdef UVStream stream = <UVStream> req.data

    if status < 0:
        exc = convert_error(status)
        stream._loop._handle_uvcb_exception(exc)
        stream._close()
        return

    try:
        stream._on_shutdown()
    except BaseException as ex:
        stream._loop._handle_uvcb_exception(ex)


cdef void __uv_stream_on_listen(uv.uv_stream_t* handle,
                                int status) with gil:

    # callback for uv_listen

    cdef:
        UVStream stream = <UVStream> handle.data

    if status < 0:
        exc = convert_error(status)
        stream._loop._handle_uvcb_exception(exc)
        stream._close()
        return

    try:
        stream._on_listen()
    except BaseException as exc:
        stream._loop._handle_uvcb_exception(exc)


cdef void __uv_stream_on_read(uv.uv_stream_t* stream,
                              ssize_t nread,
                              const uv.uv_buf_t* buf) with gil:

    # callback for uv_read_start

    cdef:
        UVStream sc = <UVStream>stream.data
        Loop loop = sc._loop

    # Free the buffer -- we'll need data from it in the code below,
    # but since we're single-threaded, the data will be available
    # till this function finishes its execution.
    __loop_free_buffer(<uv.uv_handle_t*>stream)

    if nread == uv.UV_EOF:
        try:
            sc._on_eof()
        except BaseException as ex:
            sc._loop._handle_uvcb_exception(ex)
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
        sc._close()

        exc = convert_error(nread)
        sc._loop._handle_uvcb_exception(exc)
        return

    try:
        sc._on_read(loop._recv_buffer[:nread])
    except BaseException as exc:
        loop._handle_uvcb_exception(exc)


cdef void __uv_stream_on_write(uv.uv_write_t* req, int status) with gil:
    # callback for uv_write

    cdef:
        __StreamWriteContext ctx = <__StreamWriteContext> req.data
        UVStream stream = ctx.stream
        object callback = ctx.callback

    if status < 0:
        ctx.close()
        exc = convert_error(status)
        stream._loop._handle_uvcb_exception(exc)
        stream._close()
        return

    try:
        stream._on_write()
        if callback is not None:
            callback()
    except BaseException as exc:
        stream._loop._handle_uvcb_exception(exc)
    finally:
        ctx.close()
