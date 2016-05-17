@cython.no_gc_clear
@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class _StreamWriteContext:
    # used to hold additional write request information for uv_write

    cdef:
        uv.uv_write_t   req

        list            buffers

        uv.uv_buf_t*    uv_bufs
        Py_buffer*      py_bufs
        ssize_t         py_bufs_len

        UVStream        stream

        bint            closed

    cdef close(self):
        if self.closed:
            return

        self.closed = 1

        if self.uv_bufs is not NULL:
            PyMem_Free(self.uv_bufs)
            self.uv_bufs = NULL

        if self.py_bufs is not NULL:
            for i in range(self.py_bufs_len):
                PyBuffer_Release(&self.py_bufs[i])
            PyMem_Free(self.py_bufs)
            self.py_bufs = NULL

        self.py_bufs_len = 0
        self.buffers = None

        Py_DECREF(self)

    @staticmethod
    cdef _StreamWriteContext new(UVStream stream, list buffers):
        cdef:
            _StreamWriteContext ctx
            int py_bufs_idx = 0
            int uv_bufs_idx = 0

        ctx = _StreamWriteContext.__new__(_StreamWriteContext)
        ctx.stream = None
        ctx.closed = 1
        ctx.py_bufs_len = 0
        ctx.uv_bufs = NULL
        ctx.py_bufs = NULL
        ctx.buffers = buffers
        ctx.stream = stream

        for buf in buffers:
            if not PyBytes_CheckExact(buf) and \
                    not PyByteArray_CheckExact(buf):
                ctx.py_bufs_len += 1

        if ctx.py_bufs_len > 0:
            ctx.py_bufs = <Py_buffer*>PyMem_Malloc(
                ctx.py_bufs_len * sizeof(Py_buffer))
            if ctx.py_bufs is NULL:
                raise MemoryError()

        ctx.uv_bufs = <uv.uv_buf_t*>PyMem_Malloc(
            len(buffers) * sizeof(uv.uv_buf_t))
        if ctx.uv_bufs is NULL:
            raise MemoryError()

        for buf in buffers:
            if PyBytes_CheckExact(buf):
                ctx.uv_bufs[uv_bufs_idx].base = PyBytes_AS_STRING(buf)
                ctx.uv_bufs[uv_bufs_idx].len = Py_SIZE(buf)

            elif PyByteArray_CheckExact(buf):
                ctx.uv_bufs[uv_bufs_idx].base = PyByteArray_AS_STRING(buf)
                ctx.uv_bufs[uv_bufs_idx].len = Py_SIZE(buf)

            else:
                try:
                    PyObject_GetBuffer(
                        buf, &ctx.py_bufs[py_bufs_idx], PyBUF_SIMPLE)
                except:
                    PyMem_Free(ctx.uv_bufs)
                    ctx.uv_bufs = NULL
                    for i in range(py_bufs_idx):
                        PyBuffer_Release(&ctx.py_bufs[i])
                    PyMem_Free(ctx.py_bufs)
                    ctx.py_bufs = NULL
                    ctx.py_bufs_len = 0
                    raise

                ctx.uv_bufs[uv_bufs_idx].base = \
                    <char*>ctx.py_bufs[py_bufs_idx].buf

                ctx.uv_bufs[uv_bufs_idx].len = \
                    ctx.py_bufs[py_bufs_idx].len

                py_bufs_idx += 1

            uv_bufs_idx += 1

        ctx.req.data = <void*> ctx

        IF DEBUG:
            stream._loop._debug_stream_write_ctx_total += 1
            stream._loop._debug_stream_write_ctx_cnt += 1

        # Do incref after everything else is done.
        # Under no circumstances we want `ctx` to be GCed while
        # libuv is still working with `ctx.uv_bufs`.
        Py_INCREF(ctx)
        ctx.closed = 0
        return ctx

    IF DEBUG:
        def __dealloc__(self):
            # Because we do an INCREF in _StreamWriteContext.new,
            # __dealloc__ shouldn't ever happen with `self.closed == 0`

            if not self.closed:
                raise RuntimeError(
                    'open _StreamWriteContext is being deallocated')

            if self.stream is not None:
                self.stream._loop._debug_stream_write_ctx_cnt -= 1
                self.stream = None


@cython.no_gc_clear
cdef class UVStream(UVBaseTransport):

    def __cinit__(self):
        self.__shutting_down = 0
        self.__reading = 0
        self.__read_error_close = 0
        self._eof = 0
        self._buffer = []
        self._buffer_size = 0

    cdef inline _shutdown(self):
        cdef int err

        if self.__shutting_down:
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

    cdef inline _accept(self, UVStream server):
        cdef int err
        self._ensure_alive()

        err = uv.uv_accept(<uv.uv_stream_t*>server._handle,
                           <uv.uv_stream_t*>self._handle)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

        self._on_accept()

    cdef inline _close_on_read_error(self):
        self.__read_error_close = 1

    cdef bint _is_reading(self):
        return self.__reading

    cdef _start_reading(self):
        cdef int err
        self._ensure_alive()

        if self.__reading:
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

    cdef inline __reading_started(self):
        if self.__reading:
            return
        self.__reading = 1
        Py_INCREF(self)

    cdef inline __reading_stopped(self):
        if not self.__reading:
            return
        self.__reading = 0
        Py_DECREF(self)

    cdef _stop_reading(self):
        cdef int err

        if not self.__reading:
            return

        self._ensure_alive()

        # From libuv docs:
        #    This function is idempotent and may be safely
        #    called on a stopped stream.
        err = uv.uv_read_stop(<uv.uv_stream_t*>self._handle)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return
        else:
            self.__reading_stopped()

    cdef inline _try_write(self, object data):
        cdef:
            ssize_t written
            bint used_buf = 0
            Py_buffer py_buf
            void* buf
            size_t blen
            int saved_errno
            int fd

        if PyBytes_CheckExact(data):
            buf = <void*>PyBytes_AS_STRING(data)
            blen = Py_SIZE(data)
        elif PyByteArray_CheckExact(data):
            buf = <void*>PyByteArray_AS_STRING(data)
            blen = Py_SIZE(data)
        else:
            PyObject_GetBuffer(data, &py_buf, PyBUF_SIMPLE)
            used_buf = 1
            buf = py_buf.buf
            blen = py_buf.len

        if blen == 0:
            # Empty data, do nothing.
            return 0

        fd = self._fileno()
        # Use `unistd.h/write` directly, it's faster than
        # uv_try_write -- less layers of code.  The error
        # checking logic is copied from libuv.
        written = system.write(fd, buf, blen)
        while written == -1 and (errno.errno == errno.EINTR or
                                 (system.PLATFORM_IS_APPLE and
                                    errno.errno == errno.EPROTOTYPE)):
            # From libuv code (unix/stream.c):
            #   Due to a possible kernel bug at least in OS X 10.10 "Yosemite",
            #   EPROTOTYPE can be returned while trying to write to a socket
            #   that is shutting down. If we retry the write, we should get
            #   the expected EPIPE instead.
            written = system.write(fd, buf, blen)
        saved_errno = errno.errno

        if used_buf:
            PyBuffer_Release(&py_buf)

        if written < 0:
            if saved_errno == errno.EAGAIN or \
                    saved_errno == system.EWOULDBLOCK:
                return -1
            else:
                exc = convert_error(-saved_errno)
                self._fatal_error(exc, True)
                return

        IF DEBUG:
            self._loop._debug_stream_write_tries += 1

        if <size_t>written == blen:
            return 0

        return written

    cdef inline _write(self, object data):
        cdef int dlen

        if not self._get_write_buffer_size():
            # Try to write without polling only when there is
            # no data in write buffers.
            sent = self._try_write(data)
            if sent is None:
                # A `self._fatal_error` was called.
                # It might not raise an exception under some
                # conditions.
                return
            if sent == 0:
                # All data was successfully written.
                return
            if sent > 0:
                IF DEBUG:
                    if sent == len(data):
                        raise RuntimeError(
                            '_try_write sent all data and returned non-zero')
                if not isinstance(data, memoryview):
                    data = memoryview(data)
                data = data[sent:]

                dlen = len(data)
                if dlen:
                    self._buffer_size += dlen
                    self._buffer.append(data)
                    self._loop._queue_write(self)
                return

        if not PyBytes_CheckExact(data) and not PyByteArray_CheckExact(data):
            data = memoryview(data).cast('b')

        dlen = len(data)
        if not dlen:
            return

        self._buffer_size += dlen
        self._buffer.append(data)
        self._loop._queue_write(self)

        self._maybe_pause_protocol()

    cdef inline _exec_write(self):
        cdef:
            int err
            _StreamWriteContext ctx

        ctx = _StreamWriteContext.new(self, self._buffer)

        err = uv.uv_write(&ctx.req,
                          <uv.uv_stream_t*>self._handle,
                          ctx.uv_bufs,
                          len(self._buffer),
                          __uv_stream_on_write)

        self._buffer_size = 0
        self._buffer = []

        if err < 0:
            # close write context
            ctx.close()

            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

        self._maybe_pause_protocol()

    cdef size_t _get_write_buffer_size(self):
        if self._handle is NULL:
            return 0
        return ((<uv.uv_stream_t*>self._handle).write_queue_size +
                self._buffer_size)

    cdef _close(self):
        try:
            self._stop_reading()
        finally:
            UVSocketHandle._close(<UVHandle>self)

    cdef inline _on_accept(self):
        # Ultimately called by __uv_stream_on_listen.
        self._init_protocol()

    cdef inline _on_read(self, bytes buf):
        # Any exception raised here will be caught in
        # __uv_stream_on_read.
        self._protocol_data_received(buf)

    cdef inline _on_eof(self):
        # Any exception raised here will be caught in
        # __uv_stream_on_read.

        try:
            meth = self._protocol.eof_received
        except AttributeError:
            keep_open = False
        else:
            keep_open = meth()

        if keep_open:
            # We're keeping the connection open so the
            # protocol can write more, but we still can't
            # receive more, so remove the reader callback.
            self._stop_reading()
        else:
            self.close()

    cdef inline _on_write(self):
        self._maybe_resume_protocol()
        if not self._get_write_buffer_size():
            if self._closing:
                self._schedule_call_connection_lost(None)
            elif self._eof:
                self._shutdown()

    cdef inline _init(self, Loop loop, object protocol, Server server,
                      object waiter):

        self._start_init(loop)

        if protocol is None:
            raise TypeError('protocol is required')

        self._set_protocol(protocol)

        if server is not None:
            self._set_server(server)

        if waiter is not None:
            self._set_waiter(waiter)

    cdef inline _on_connect(self, object exc):
        # Called from __tcp_connect_callback (tcp.pyx) and
        # __pipe_connect_callback (pipe.pyx).
        if exc is None:
            self._init_protocol()
        else:
            if self._waiter is None or self._waiter.done():
                self._fatal_error(exc, False, "connect failed")
            else:
                self._waiter.set_exception(exc)
                self._close()

    # === Public API ===

    def __repr__(self):
        return '<{} closed={} reading={} {:#x}>'.format(
            self.__class__.__name__,
            self._closed,
            self.__reading,
            id(self))

    def write(self, object buf):
        self._ensure_alive()

        if self._eof:
            raise RuntimeError('Cannot call write() after write_eof()')
        if not buf:
            return
        if self._conn_lost:
            self._conn_lost += 1
            return
        self._write(buf)
        self._maybe_pause_protocol()

    def writelines(self, bufs):
        # Instead of flattening the buffers into one bytes object,
        # we could simply call `self._write` multiple times.  That
        # would be more efficient, as we wouldn't be copying data
        # (and thus allocating more memory).
        # On the other hand, uvloop would behave differently from
        # asyncio: where asyncio does one send op, uvloop would do
        # many send ops.  If the program doesn't use the TCP_NODELAY
        # sock opt (and by default asyncio programs do not set it),
        # this different behavior may result in uvloop being slower
        # than asyncio.
        self.write(b''.join(bufs))

    def write_eof(self):
        self._ensure_alive()

        if self._eof:
            return

        self._eof = 1
        if not self._get_write_buffer_size():
            self._shutdown()

    def can_write_eof(self):
        return True

    def pause_reading(self):
        self._ensure_alive()

        if self._closing:
            raise RuntimeError('Cannot pause_reading() when closing')
        if not self._is_reading():
            raise RuntimeError('Already paused')
        self._stop_reading()

    def resume_reading(self):
        self._ensure_alive()

        if self._is_reading():
            raise RuntimeError('Not paused')
        if self._closing:
            return
        self._start_reading()


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


cdef inline void __uv_stream_on_read_impl(uv.uv_stream_t* stream,
                                          ssize_t nread,
                                          const uv.uv_buf_t* buf):
    cdef:
        UVStream sc = <UVStream>stream.data
        Loop loop = sc._loop

    # It's OK to free the buffer early, since nothing will
    # be able to touch it until this method is done.
    __loop_free_buffer(loop)

    if sc._closed:
        # The stream was closed, there is no reason to
        # do any work now.
        sc.__reading_stopped()  # Just in case.
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

        if sc.__read_error_close:
            # Used for getting notified when a pipe is closed.
            # See WriteUnixTransport for the explanation.
            sc._on_eof()
            return

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


cdef inline void __uv_stream_on_write_impl(uv.uv_write_t* req, int status):
    cdef:
        _StreamWriteContext ctx = <_StreamWriteContext> req.data
        UVStream stream = <UVStream>ctx.stream

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


cdef void __uv_stream_on_read(uv.uv_stream_t* stream,
                              ssize_t nread,
                              const uv.uv_buf_t* buf) with gil:

    if __ensure_handle_data(<uv.uv_handle_t*>stream,
                            "UVStream read callback") == 0:
        return

    cdef:
        Loop loop = <Loop>stream.loop.data
        bint old_exec_py_code

    old_exec_py_code = loop._executing_py_code
    loop._executing_py_code = 1
    # Don't need try-finally, __uv_stream_on_read_impl is void
    __uv_stream_on_read_impl(stream, nread, buf)
    loop._executing_py_code = old_exec_py_code


cdef void __uv_stream_on_write(uv.uv_write_t* req, int status) with gil:

    IF DEBUG:
        if req.data is NULL:
            aio_logger.error(
                'UVStream.write callback called with NULL req.data, status=%r',
                status)
            return

    cdef:
        Loop loop = <UVStream>(<_StreamWriteContext> req.data).stream._loop
        bint old_exec_py_code

    old_exec_py_code = loop._executing_py_code
    loop._executing_py_code = 1
    # Don't need try-finally, __uv_stream_on_write_impl is void
    __uv_stream_on_write_impl(req, status)
    loop._executing_py_code = old_exec_py_code
