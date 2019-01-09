import functools


@functools.lru_cache()
def validate_address(object addr, int sock_family, int sock_type,
                     int sock_proto):
    addrinfo = __static_getaddrinfo_pyaddr(
        addr[0], addr[1],
        uv.AF_UNSPEC, sock_type, sock_proto, 0)
    if addrinfo is None:
        raise ValueError(
            'UDP.sendto(): address {!r} requires a DNS lookup'.format(addr))
    if addrinfo[0] != sock_family:
        raise ValueError(
            'UDP.sendto(): {!r} socket family mismatch'.format(addr))


cdef class UDPTransport(UVBaseTransport):

    def __cinit__(self):
        self.sock = None
        self.poll = None
        self.buffer = col_deque()
        self._has_handle = 0

    cdef _init(self, Loop loop, object sock, object r_addr):
        self._start_init(loop)
        try:
            # It's important to incref the socket in case it
            # was created outside of uvloop,
            # i.e. `look.create_datagram_endpoint(sock=sock)`.
            socket_inc_io_ref(sock)

            self.sock = sock
            self.sock_family = sock.family
            self.sock_proto = sock.proto
            self.sock_type = sock.type
            self.address = r_addr
            self.poll = UVPoll.new(loop, sock.fileno())
            self._finish_init()
        except:
            self._free()
            self._abort_init()
            raise

    cdef size_t _get_write_buffer_size(self):
        cdef int size = 0
        for data, addr in self.buffer:
            size += len(data)
        return size

    cdef _fileno(self):
        return self.sock.fileno()

    cdef bint _is_reading(self):
        return self.poll is not None and self.poll.is_reading()

    cdef _start_reading(self):
        self._ensure_alive()

        self.poll.start_reading(
            new_MethodHandle(
                self._loop,
                "UDPTransport._on_read_ready",
                <method_t>self._on_read_ready,
                self))

    cdef _stop_reading(self):
        self._ensure_alive()
        self.poll.stop_reading()

    cdef _on_read_ready(self):
        if self._conn_lost:
            return
        try:
            data, addr = self.sock.recvfrom(UV_STREAM_RECV_BUF_SIZE)
        except (BlockingIOError, InterruptedError):
            pass
        except OSError as exc:
            self._protocol.error_received(exc)
        except Exception as exc:
            self._fatal_error(exc, 'Fatal read error on datagram transport')
        else:
            self._protocol.datagram_received(data, addr)

    cdef _on_write_ready(self):
        while self.buffer:
            data, addr = self.buffer.popleft()
            try:
                if self.address:
                    self.sock.send(data)
                else:
                    self.sock.sendto(data, addr)
            except (BlockingIOError, InterruptedError):
                self.buffer.appendleft((data, addr))  # Try again later.
                break
            except OSError as exc:
                self._protocol.error_received(exc)
                return
            except Exception as exc:
                self._fatal_error(
                    exc, 'Fatal write error on datagram transport')
                return

        self._maybe_resume_protocol()  # May append to buffer.
        if not self.buffer:
            self.poll.stop_writing()
            if self._closing:
                self._call_connection_lost(None)

    cdef _new_socket(self):
        return PseudoSocket(self.sock.family, self.sock.type,
                            self.sock.proto, self.sock.fileno())

    @staticmethod
    cdef UDPTransport new(Loop loop, object sock, object r_addr):
        cdef UDPTransport udp
        udp = UDPTransport.__new__(UDPTransport)
        udp._init(loop, sock, r_addr)
        return udp

    def __dealloc__(self):
        if UVLOOP_DEBUG:
            self._loop._debug_uv_handles_freed += 1

        if self._closed == 0:
            self._warn_unclosed()
            self._close()

    cdef _free(self):
        if self.poll is not None:
            self.poll._close()
            self.poll = None

        if self.sock is not None:
            try:
                socket_dec_io_ref(self.sock)
                self.sock.close()
            finally:
                self.sock = None

        UVBaseTransport._free(self)

    cdef _close(self):
        self._free()

        if UVLOOP_DEBUG:
            self._loop._debug_handles_closed.update([
                self.__class__.__name__])

        UVSocketHandle._close(<UVSocketHandle>self)

    def sendto(self, data, addr=None):
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise TypeError('data argument must be a bytes-like object, '
                            'not {!r}'.format(type(data).__name__))
        if not data:
            return

        if self.address and addr not in (None, self.address):
            raise ValueError(
                'Invalid address: must be None or {}'.format(self.address))

        if addr is not None and self.sock_family != uv.AF_UNIX:
            validate_address(addr, self.sock_family, self.sock_type,
                             self.sock_proto)

        if self._conn_lost:
            if self._conn_lost >= LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                aio_logger.warning('socket.send() raised exception.')
            self._conn_lost += 1
            return

        if not self.buffer:
            # Attempt to send it right away first.
            try:
                if self.address:
                    self.sock.send(data)
                else:
                    self.sock.sendto(data, addr)
                return
            except (BlockingIOError, InterruptedError):
                self.poll.start_writing(
                    new_MethodHandle(
                        self._loop,
                        "UDPTransport._on_write_ready",
                        <method_t>self._on_write_ready,
                        self))
            except OSError as exc:
                self._protocol.error_received(exc)
                return
            except Exception as exc:
                self._fatal_error(
                    exc, 'Fatal write error on datagram transport')
                return

        # Ensure that what we buffer is immutable.
        self.buffer.append((bytes(data), addr))
        self._maybe_pause_protocol()
