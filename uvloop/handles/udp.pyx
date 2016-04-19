@cython.no_gc_clear
@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class _UDPSendContext:
    # used to hold additional write request information for uv_write

    cdef:
        uv.uv_udp_send_t   req

        uv.uv_buf_t     uv_buf
        Py_buffer       py_buf

        UDPTransport    udp

        bint            closed

        system.sockaddr addr

    cdef close(self):
        if self.closed:
            return

        self.closed = 1
        PyBuffer_Release(&self.py_buf)  # void
        self.req.data = NULL
        Py_DECREF(self)
        self.udp = None

    @staticmethod
    cdef _UDPSendContext new(UDPTransport udp, object data):
        cdef _UDPSendContext ctx
        ctx = _UDPSendContext.__new__(_UDPSendContext)
        ctx.udp = None
        ctx.closed = 1

        ctx.req.data = <void*> ctx
        Py_INCREF(ctx)

        PyObject_GetBuffer(data, &ctx.py_buf, PyBUF_SIMPLE)
        ctx.uv_buf = uv.uv_buf_init(<char*>ctx.py_buf.buf, ctx.py_buf.len)
        ctx.udp = udp

        ctx.closed = 0
        return ctx

    IF DEBUG:
        def __dealloc__(self):
            if not self.closed:
                raise RuntimeError(
                    'open _UDPSendContext is being deallocated')
            self.udp = None


@cython.no_gc_clear
cdef class UDPTransport(UVBaseTransport):
    def __cinit__(self):
        self._family = uv.AF_UNSPEC
        self._address_set = 0
        self.__receiving = 0
        self._cached_py_address = None

    cdef _init(self, Loop loop, unsigned int family):
        cdef int err

        self._start_init(loop)

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_udp_t))
        if self._handle is NULL:
            self._abort_init()
            raise MemoryError()

        err = uv.uv_udp_init_ex(loop.uvloop,
                                <uv.uv_udp_t*>self._handle,
                                family)
        if err < 0:
            self._abort_init()
            raise convert_error(err)

        if family in (uv.AF_INET, uv.AF_INET6):
            self._family = family

        self._finish_init()

    cdef _set_remote_address(self, system.sockaddr address):
        self._address_set = 1
        self._address = address

    cdef _open(self, int family, int sockfd):
        if family in (uv.AF_INET, uv.AF_INET6):
            self._family = family
        else:
            raise ValueError(
                'cannot open a UDP handle, invalid family {}'.format(family))

        cdef int err
        err = uv.uv_udp_open(<uv.uv_udp_t*>self._handle,
                             <uv.uv_os_sock_t>sockfd)

        if err < 0:
            exc = convert_error(err)
            raise exc

    cdef _bind(self, system.sockaddr* addr, bint reuse_addr):
        cdef:
            int err
            int flags = 0

        self._ensure_alive()

        if reuse_addr:
            flags |= uv.UV_UDP_REUSEADDR

        err = uv.uv_udp_bind(<uv.uv_udp_t*>self._handle, addr, flags)
        if err < 0:
            exc = convert_error(err)
            raise exc

    cdef _set_broadcast(self, bint on):
        cdef int err

        self._ensure_alive()

        err = uv.uv_udp_set_broadcast(<uv.uv_udp_t*>self._handle, on)
        if err < 0:
            exc = convert_error(err)
            raise exc

    cdef size_t _get_write_buffer_size(self):
        if self._handle is NULL:
            return 0
        return (<uv.uv_udp_t*>self._handle).send_queue_size

    cdef bint _is_reading(self):
        return self.__receiving

    cdef _start_reading(self):
        cdef int err

        if self.__receiving:
            return

        self._ensure_alive()

        err = uv.uv_udp_recv_start(<uv.uv_udp_t*>self._handle,
                                   __loop_alloc_buffer,
                                   __uv_udp_on_receive)

        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return
        else:
            # UDPTransport must live until the read callback is called
            self.__receiving_started()

    cdef _stop_reading(self):
        cdef int err

        if not self.__receiving:
            return

        self._ensure_alive()

        err = uv.uv_udp_recv_stop(<uv.uv_udp_t*>self._handle)
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return
        else:
            self.__receiving_stopped()

    cdef inline __receiving_started(self):
        if self.__receiving:
            return
        self.__receiving = 1
        Py_INCREF(self)

    cdef inline __receiving_stopped(self):
        if not self.__receiving:
            return
        self.__receiving = 0
        Py_DECREF(self)

    cdef _new_socket(self):
        if self._family not in (uv.AF_INET, uv.AF_INET6):
            raise RuntimeError(
                'UDPTransport.family is undefined; cannot create python socket')

        fileno = self._fileno()
        return socket_socket(self._family, uv.SOCK_STREAM, 0, fileno)

    cdef _send(self, object data, object addr):
        cdef:
            _UDPSendContext ctx

        if self._family not in (uv.AF_INET, uv.AF_INET6):
            raise RuntimeError('UDPTransport.family is undefined; cannot send')

        if self._address_set and addr is not None:
            if self._cached_py_address is None:
                self._cached_py_address = __convert_sockaddr_to_pyaddr(
                    &self._address)

            if self._cached_py_address != addr:
                raise ValueError('Invalid address: must be None or %s' %
                                 (self._cached_py_address,))

            addr = None

        ctx = _UDPSendContext.new(self, data)
        try:
            if addr is None:
                if self._address_set:
                    ctx.addr = self._address
                else:
                    raise RuntimeError(
                        'undable to perform send operation: no address')
            else:
                __convert_pyaddr_to_sockaddr(self._family, addr, &ctx.addr)
        except:
            ctx.close()
            raise

        err = uv.uv_udp_send(&ctx.req,
                             <uv.uv_udp_t*>self._handle,
                             &ctx.uv_buf,
                             1,
                             &ctx.addr,
                             __uv_udp_on_send)

        if err < 0:
            ctx.close()

            exc = convert_error(err)
            self._fatal_error(exc, True)

    cdef _on_receive(self, bytes data, object exc, object addr):
        if exc is None:
            self._protocol.datagram_received(data, addr)
        else:
            self._protocol.error_received(exc)

    cdef _on_sent(self, object exc):
        if exc is not None:
            if isinstance(exc, OSError):
                self._protocol.error_received(exc)
            else:
                self._fatal_error(
                    exc, False, 'Fatal write error on datagram transport')

        self._maybe_resume_protocol()
        if not self._get_write_buffer_size():
            if self._closing:
                self._schedule_call_connection_lost(None)

    # === Public API ===

    def sendto(self, data, addr=None):
        if not data:
            return

        if self._conn_lost:
            # TODO add warning
            self._conn_lost += 1
            return

        self._send(data, addr)
        self._maybe_pause_protocol()


cdef void __uv_udp_on_receive(uv.uv_udp_t* handle,
                              ssize_t nread,
                              const uv.uv_buf_t* buf,
                              const system.sockaddr* addr,
                              unsigned flags) with gil:

    if __ensure_handle_data(<uv.uv_handle_t*>handle,
                            "UDPTransport receive callback") == 0:
        return

    cdef:
        UDPTransport udp = <UDPTransport>handle.data
        Loop loop = udp._loop
        bytes data
        object pyaddr

    # It's OK to free the buffer early, since nothing will
    # be able to touch it until this method is done.
    __loop_free_buffer(loop)

    if udp._closed:
        # The handle was closed, there is no reason to
        # do any work now.
        udp.__receiving_stopped()  # Just in case.
        return

    if addr is NULL and nread == 0:
        # From libuv docs:
        #      addr: struct sockaddr* containing the address
        #      of the sender. Can be NULL. Valid for the duration
        #      of the callback only.
        #      [...]
        #      The receive callback will be called with
        #      nread == 0 and addr == NULL when there is
        #      nothing to read, and with nread == 0 and
        #      addr != NULL when an empty UDP packet is
        #      received.
        return

    if addr is NULL:
        pyaddr = None
    else:
        try:
            pyaddr = __convert_sockaddr_to_pyaddr(addr)
        except BaseException as exc:
            udp._error(exc, False)
            return

    if nread < 0:
        exc = convert_error(nread)
        udp._on_receive(None, exc, pyaddr)
        return

    if pyaddr is None:
        udp._fatal_error(
            RuntimeError(
                'uv_udp.receive callback: addr is NULL and nread >= 0'),
            False)
        return

    if nread == 0:
        data = b''
    else:
        data = loop._recv_buffer[:nread]

    try:
        udp._on_receive(data, None, pyaddr)
    except BaseException as exc:
        udp._error(exc, False)


cdef void __uv_udp_on_send(uv.uv_udp_send_t* req, int status) with gil:

    if req.data is NULL:
        # Shouldn't happen as:
        #    - _UDPSendContext does an extra INCREF in its 'init()'
        #    - _UDPSendContext holds a ref to the relevant UDPTransport
        aio_logger.error(
            'UVStream.write callback called with NULL req.data, status=%r',
            status)
        return

    cdef:
        _UDPSendContext ctx = <_UDPSendContext> req.data
        UDPTransport udp = <UDPTransport>ctx.udp

    ctx.close()

    if status < 0:
        exc = convert_error(status)
        print(exc)
    else:
        exc = None

    try:
        udp._on_sent(exc)
    except BaseException as exc:
        udp._error(exc, False)
