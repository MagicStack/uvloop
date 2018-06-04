# Adapted from CPython/Lib/asyncio/sslproto.py.
# License: PSFL.

cdef _create_transport_context(server_side, server_hostname):
    if server_side:
        raise ValueError('Server side SSL needs a valid SSLContext')

    # Client side may pass ssl=True to use a default
    # context; in that case the sslcontext passed is None.
    # The default is secure for client connections.
    # Python 3.4+: use up-to-date strong settings.
    sslcontext = ssl_create_default_context()
    if not server_hostname:
        sslcontext.check_hostname = False
    return sslcontext


# States of an _SSLPipe.
cdef:
    str _UNWRAPPED = "UNWRAPPED"
    str _DO_HANDSHAKE = "DO_HANDSHAKE"
    str _WRAPPED = "WRAPPED"
    str _SHUTDOWN = "SHUTDOWN"


cdef int READ_MAX_SIZE = 256 * 1024


@cython.no_gc_clear
cdef class _SSLPipe:
    """An SSL "Pipe".

    An SSL pipe allows you to communicate with an SSL/TLS protocol instance
    through memory buffers. It can be used to implement a security layer for an
    existing connection where you don't have access to the connection's file
    descriptor, or for some reason you don't want to use it.

    An SSL pipe can be in "wrapped" and "unwrapped" mode. In unwrapped mode,
    data is passed through untransformed. In wrapped mode, application level
    data is encrypted to SSL record level data and vice versa. The SSL record
    level is the lowest level in the SSL protocol suite and is what travels
    as-is over the wire.

    An SslPipe initially is in "unwrapped" mode. To start SSL, call
    do_handshake(). To shutdown SSL again, call unwrap().
    """

    cdef:
        object _context
        object _server_side
        object _server_hostname
        object _state
        object _incoming
        object _outgoing
        object _sslobj
        bint _need_ssldata
        object _handshake_cb
        object _shutdown_cb


    def __init__(self, context, server_side, server_hostname=None):
        """
        The *context* argument specifies the ssl.SSLContext to use.

        The *server_side* argument indicates whether this is a server side or
        client side transport.

        The optional *server_hostname* argument can be used to specify the
        hostname you are connecting to. You may only specify this parameter if
        the _ssl module supports Server Name Indication (SNI).
        """
        self._context = context
        self._server_side = server_side
        self._server_hostname = server_hostname
        self._state = _UNWRAPPED
        self._incoming = ssl_MemoryBIO()
        self._outgoing = ssl_MemoryBIO()
        self._sslobj = None
        self._need_ssldata = False
        self._handshake_cb = None
        self._shutdown_cb = None

    cdef do_handshake(self, callback=None):
        """Start the SSL handshake.

        Return a list of ssldata. A ssldata element is a list of buffers

        The optional *callback* argument can be used to install a callback that
        will be called when the handshake is complete. The callback will be
        called with None if successful, else an exception instance.
        """
        if self._state is not _UNWRAPPED:
            raise RuntimeError('handshake in progress or completed')
        self._sslobj = self._context.wrap_bio(
            self._incoming, self._outgoing,
            server_side=self._server_side,
            server_hostname=self._server_hostname)
        self._state = _DO_HANDSHAKE
        self._handshake_cb = callback
        ssldata, appdata = self.feed_ssldata(b'', only_handshake=True)
        assert len(appdata) == 0
        return ssldata

    cdef shutdown(self, callback=None):
        """Start the SSL shutdown sequence.

        Return a list of ssldata. A ssldata element is a list of buffers

        The optional *callback* argument can be used to install a callback that
        will be called when the shutdown is complete. The callback will be
        called without arguments.
        """
        if self._state is _UNWRAPPED:
            raise RuntimeError('no security layer present')
        if self._state is _SHUTDOWN:
            raise RuntimeError('shutdown in progress')
        assert self._state in (_WRAPPED, _DO_HANDSHAKE)
        self._state = _SHUTDOWN
        self._shutdown_cb = callback
        ssldata, appdata = self.feed_ssldata(b'')
        assert appdata == [] or appdata == [b'']
        return ssldata

    cdef feed_eof(self):
        """Send a potentially "ragged" EOF.

        This method will raise an SSL_ERROR_EOF exception if the EOF is
        unexpected.
        """
        self._incoming.write_eof()
        ssldata, appdata = self.feed_ssldata(b'')
        assert appdata == [] or appdata == [b'']

    cdef feed_ssldata(self, data, bint only_handshake=False):
        """Feed SSL record level data into the pipe.

        The data must be a bytes instance. It is OK to send an empty bytes
        instance. This can be used to get ssldata for a handshake initiated by
        this endpoint.

        Return a (ssldata, appdata) tuple. The ssldata element is a list of
        buffers containing SSL data that needs to be sent to the remote SSL.

        The appdata element is a list of buffers containing plaintext data that
        needs to be forwarded to the application. The appdata list may contain
        an empty buffer indicating an SSL "close_notify" alert. This alert must
        be acknowledged by calling shutdown().
        """
        cdef:
            list appdata
            list ssldata
            int errno

        if self._state is _UNWRAPPED:
            # If unwrapped, pass plaintext data straight through.
            if data:
                appdata = [data]
            else:
                appdata = []
            return ([], appdata)

        self._need_ssldata = False
        if data:
            self._incoming.write(data)

        ssldata = []
        appdata = []
        try:
            if self._state is _DO_HANDSHAKE:
                # Call do_handshake() until it doesn't raise anymore.
                self._sslobj.do_handshake()
                self._state = _WRAPPED
                if self._handshake_cb:
                    self._handshake_cb(None)
                if only_handshake:
                    return (ssldata, appdata)
                # Handshake done: execute the wrapped block

            if self._state is _WRAPPED:
                # Main state: read data from SSL until close_notify
                while True:
                    chunk = self._sslobj.read(READ_MAX_SIZE)
                    appdata.append(chunk)
                    if not chunk:  # close_notify
                        break

            elif self._state is _SHUTDOWN:
                # Call shutdown() until it doesn't raise anymore.
                self._sslobj.unwrap()
                self._sslobj = None
                self._state = _UNWRAPPED
                if self._shutdown_cb:
                    self._shutdown_cb()

            elif self._state is _UNWRAPPED:
                # Drain possible plaintext data after close_notify.
                appdata.append(self._incoming.read())
        except (ssl_SSLError, ssl_CertificateError) as exc:
            errno = <int>getattr(exc, 'errno', 0)  # SSL_ERROR_NONE = 0
            if errno not in (ssl_SSL_ERROR_WANT_READ, ssl_SSL_ERROR_WANT_WRITE,
                             ssl_SSL_ERROR_SYSCALL):
                if self._state is _DO_HANDSHAKE and self._handshake_cb:
                    self._handshake_cb(exc)
                raise
            self._need_ssldata = (errno == ssl_SSL_ERROR_WANT_READ)

        # Check for record level data that needs to be sent back.
        # Happens for the initial handshake and renegotiations.
        if self._outgoing.pending:
            ssldata.append(self._outgoing.read())
        return (ssldata, appdata)

    cdef feed_appdata(self, data, int offset=0):
        """Feed plaintext data into the pipe.

        Return an (ssldata, offset) tuple. The ssldata element is a list of
        buffers containing record level data that needs to be sent to the
        remote SSL instance. The offset is the number of plaintext bytes that
        were processed, which may be less than the length of data.

        NOTE: In case of short writes, this call MUST be retried with the SAME
        buffer passed into the *data* argument (i.e. the id() must be the
        same). This is an OpenSSL requirement. A further particularity is that
        a short write will always have offset == 0, because the _ssl module
        does not enable partial writes. And even though the offset is zero,
        there will still be encrypted data in ssldata.
        """
        cdef:
            int errno
        assert 0 <= offset <= len(data)
        if self._state is _UNWRAPPED:
            # pass through data in unwrapped mode
            if offset < len(data):
                ssldata = [data[offset:]]
            else:
                ssldata = []
            return (ssldata, len(data))

        ssldata = []
        view = memoryview(data)
        while True:
            self._need_ssldata = False
            try:
                if offset < len(view):
                    offset += self._sslobj.write(view[offset:])
            except ssl_SSLError as exc:
                errno = <int>getattr(exc, 'errno', 0)  # SSL_ERROR_NONE = 0
                # It is not allowed to call write() after unwrap() until the
                # close_notify is acknowledged. We return the condition to the
                # caller as a short write.
                if exc.reason == 'PROTOCOL_IS_SHUTDOWN':
                    exc.errno = errno = ssl_SSL_ERROR_WANT_READ
                if errno not in (ssl_SSL_ERROR_WANT_READ,
                                 ssl_SSL_ERROR_WANT_WRITE,
                                 ssl_SSL_ERROR_SYSCALL):
                    raise
                self._need_ssldata = (errno == ssl_SSL_ERROR_WANT_READ)

            # See if there's any record level data back for us.
            if self._outgoing.pending:
                ssldata.append(self._outgoing.read())
            if offset == len(view) or self._need_ssldata:
                break
        return (ssldata, offset)


class _SSLProtocolTransport(aio_FlowControlMixin, aio_Transport):

    # TODO:
    # _sendfile_compatible = constants._SendfileMode.FALLBACK

    def __init__(self, loop, ssl_protocol):
        self._loop = loop
        # SSLProtocol instance
        self._ssl_protocol = ssl_protocol
        self._closed = False

    def get_extra_info(self, name, default=None):
        """Get optional transport information."""
        return self._ssl_protocol._get_extra_info(name, default)

    def set_protocol(self, protocol):
        self._ssl_protocol._set_app_protocol(protocol)

    def get_protocol(self):
        return self._ssl_protocol._app_protocol

    def is_closing(self):
        return self._closed

    def close(self):
        """Close the transport.

        Buffered data will be flushed asynchronously.  No more data
        will be received.  After all buffered data is flushed, the
        protocol's connection_lost() method will (eventually) called
        with None as its argument.
        """
        self._closed = True
        self._ssl_protocol._start_shutdown()

    def __del__(self):
        if not self._closed:
            _warn_with_source(
                "unclosed transport {!r}".format(self),
                ResourceWarning, self)
            self.close()

    def is_reading(self):
        tr = self._ssl_protocol._transport
        if tr is None:
            raise RuntimeError('SSL transport has not been initialized yet')
        return tr.is_reading()

    def pause_reading(self):
        """Pause the receiving end.

        No data will be passed to the protocol's data_received()
        method until resume_reading() is called.
        """
        self._ssl_protocol._transport.pause_reading()

    def resume_reading(self):
        """Resume the receiving end.

        Data received will once again be passed to the protocol's
        data_received() method.
        """
        self._ssl_protocol._transport.resume_reading()

    def set_write_buffer_limits(self, high=None, low=None):
        """Set the high- and low-water limits for write flow control.

        These two values control when to call the protocol's
        pause_writing() and resume_writing() methods.  If specified,
        the low-water limit must be less than or equal to the
        high-water limit.  Neither value can be negative.

        The defaults are implementation-specific.  If only the
        high-water limit is given, the low-water limit defaults to an
        implementation-specific value less than or equal to the
        high-water limit.  Setting high to zero forces low to zero as
        well, and causes pause_writing() to be called whenever the
        buffer becomes non-empty.  Setting low to zero causes
        resume_writing() to be called only once the buffer is empty.
        Use of zero for either limit is generally sub-optimal as it
        reduces opportunities for doing I/O and computation
        concurrently.
        """
        self._ssl_protocol._transport.set_write_buffer_limits(high, low)

    def get_write_buffer_size(self):
        """Return the current size of the write buffer."""
        return self._ssl_protocol._transport.get_write_buffer_size()

    @property
    def _protocol_paused(self):
        # Required for sendfile fallback pause_writing/resume_writing logic
        return self._ssl_protocol._transport._protocol_paused

    def write(self, data):
        """Write some data bytes to the transport.

        This does not block; it buffers the data and arranges for it
        to be sent out asynchronously.
        """
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise TypeError(f"data: expecting a bytes-like instance, "
                            f"got {type(data).__name__}")
        if not data:
            return
        self._ssl_protocol._write_appdata(data)

    def can_write_eof(self):
        """Return True if this transport supports write_eof(), False if not."""
        return False

    def abort(self):
        """Close the transport immediately.

        Buffered data will be lost.  No more data will be received.
        The protocol's connection_lost() method will (eventually) be
        called with None as its argument.
        """
        self._ssl_protocol._abort()


class SSLProtocol(object):
    """SSL protocol.

    Implementation of SSL on top of a socket using incoming and outgoing
    buffers which are ssl.MemoryBIO objects.
    """

    def __init__(self, loop, app_protocol, sslcontext, waiter,
                 server_side=False, server_hostname=None,
                 call_connection_made=True,
                 ssl_handshake_timeout=None):
        if ssl_handshake_timeout is None:
            ssl_handshake_timeout = SSL_HANDSHAKE_TIMEOUT
        elif ssl_handshake_timeout <= 0:
            raise ValueError(
                f"ssl_handshake_timeout should be a positive number, "
                f"got {ssl_handshake_timeout}")

        if not sslcontext:
            sslcontext = _create_transport_context(
                server_side, server_hostname)

        self._server_side = server_side
        if server_hostname and not server_side:
            self._server_hostname = server_hostname
        else:
            self._server_hostname = None
        self._sslcontext = sslcontext
        # SSL-specific extra info. More info are set when the handshake
        # completes.
        self._extra = dict(sslcontext=sslcontext)

        # App data write buffering
        self._write_backlog = col_deque()
        self._write_buffer_size = 0

        self._waiter = waiter
        self._loop = loop
        self._set_app_protocol(app_protocol)
        self._app_transport = None
        # _SSLPipe instance (None until the connection is made)
        self._sslpipe = None
        self._session_established = False
        self._in_handshake = False
        self._in_shutdown = False
        # transport, ex: SelectorSocketTransport
        self._transport = None
        self._call_connection_made = call_connection_made
        self._ssl_handshake_timeout = ssl_handshake_timeout

    def _set_app_protocol(self, app_protocol):
        self._app_protocol = app_protocol
        self._app_protocol_is_buffer = (
            not hasattr(app_protocol, 'data_received') and
            hasattr(app_protocol, 'get_buffer')
        )

    def _wakeup_waiter(self, exc=None):
        if self._waiter is None:
            return
        if not self._waiter.cancelled():
            if exc is not None:
                self._waiter.set_exception(exc)
            else:
                self._waiter.set_result(None)
        self._waiter = None

    def connection_made(self, transport):
        """Called when the low-level connection is made.

        Start the SSL handshake.
        """
        self._transport = transport
        self._sslpipe = _SSLPipe(self._sslcontext,
                                 self._server_side,
                                 self._server_hostname)
        self._start_handshake()

    def connection_lost(self, exc):
        """Called when the low-level connection is lost or closed.

        The argument is an exception object or None (the latter
        meaning a regular EOF is received or the connection was
        aborted or closed).
        """
        if self._session_established:
            self._session_established = False
            self._loop.call_soon(self._app_protocol.connection_lost, exc)

        self._transport = None
        self._app_transport = None
        self._wakeup_waiter(exc)

    def pause_writing(self):
        """Called when the low-level transport's buffer goes over
        the high-water mark.
        """
        self._app_protocol.pause_writing()

    def resume_writing(self):
        """Called when the low-level transport's buffer drains below
        the low-water mark.
        """
        self._app_protocol.resume_writing()

    def data_received(self, data):
        """Called when some SSL data is received.

        The argument is a bytes object.
        """
        if self._sslpipe is None:
            # transport closing, sslpipe is destroyed
            return

        try:
            ssldata, appdata = (<_SSLPipe>self._sslpipe).feed_ssldata(data)
        except ssl_SSLError as e:
            msg = (
                f'SSL error errno:{getattr(e, "errno", "missing")} '
                f'reason: {getattr(e, "reason", "missing")}'
            )
            self._fatal_error(e, msg)
            return

        self._transport.writelines(ssldata)

        for chunk in appdata:
            if chunk:
                try:
                    if self._app_protocol_is_buffer:
                        _feed_data_to_bufferred_proto(
                            self._app_protocol, chunk)
                    else:
                        self._app_protocol.data_received(chunk)
                except Exception as ex:
                    self._fatal_error(
                        ex, 'application protocol failed to receive SSL data')
                    return
            else:
                self._start_shutdown()
                break

    def eof_received(self):
        """Called when the other end of the low-level stream
        is half-closed.

        If this returns a false value (including None), the transport
        will close itself.  If it returns a true value, closing the
        transport is up to the protocol.
        """
        try:
            if self._loop.get_debug():
                aio_logger.debug("%r received EOF", self)

            self._wakeup_waiter(ConnectionResetError)

            if not self._in_handshake:
                keep_open = self._app_protocol.eof_received()
                if keep_open:
                    aio_logger.warning('returning true from eof_received() '
                                       'has no effect when using ssl')
        finally:
            self._transport.close()

    def _get_extra_info(self, name, default=None):
        if name in self._extra:
            return self._extra[name]
        elif self._transport is not None:
            return self._transport.get_extra_info(name, default)
        else:
            return default

    def _mark_closed(self):
        self._closed = True

    def _start_shutdown(self):
        if self._in_shutdown:
            return
        if self._in_handshake:
            self._abort()
        else:
            self._in_shutdown = True
            self._write_appdata(b'')

    def _write_appdata(self, data):
        self._write_backlog.append((data, 0))
        self._write_buffer_size += len(data)
        self._process_write_backlog()

    def _start_handshake(self):
        if self._loop.get_debug():
            aio_logger.debug("%r starts SSL handshake", self)
            self._handshake_start_time = self._loop.time()
        else:
            self._handshake_start_time = None
        self._in_handshake = True
        # (b'', 1) is a special value in _process_write_backlog() to do
        # the SSL handshake
        self._write_backlog.append((b'', 1))
        self._handshake_timeout_handle = \
            self._loop.call_later(self._ssl_handshake_timeout,
                                  self._check_handshake_timeout)
        self._process_write_backlog()

    def _check_handshake_timeout(self):
        if self._in_handshake is True:
            msg = (
                f"SSL handshake is taking longer than "
                f"{self._ssl_handshake_timeout} seconds: "
                f"aborting the connection"
            )
            self._fatal_error(ConnectionAbortedError(msg))

    def _on_handshake_complete(self, handshake_exc):
        self._in_handshake = False
        self._handshake_timeout_handle.cancel()

        sslobj = (<_SSLPipe>self._sslpipe)._sslobj
        try:
            if handshake_exc is not None:
                raise handshake_exc

            peercert = sslobj.getpeercert()
        except Exception as exc:
            if isinstance(exc, ssl_CertificateError):
                msg = 'SSL handshake failed on verifying the certificate'
            else:
                msg = 'SSL handshake failed'
            self._fatal_error(exc, msg)
            return

        if self._loop.get_debug():
            dt = self._loop.time() - self._handshake_start_time
            aio_logger.debug("%r: SSL handshake took %.1f ms", self, dt * 1e3)

        # Add extra info that becomes available after handshake.
        self._extra.update(peercert=peercert,
                           cipher=sslobj.cipher(),
                           compression=sslobj.compression(),
                           ssl_object=sslobj)

        self._app_transport = _SSLProtocolTransport(self._loop, self)

        if self._call_connection_made:
            self._app_protocol.connection_made(self._app_transport)
        self._wakeup_waiter()
        self._session_established = True
        # In case transport.write() was already called. Don't call
        # immediately _process_write_backlog(), but schedule it:
        # _on_handshake_complete() can be called indirectly from
        # _process_write_backlog(), and _process_write_backlog() is not
        # reentrant.
        self._loop.call_soon(self._process_write_backlog)

    def _process_write_backlog(self):
        # Try to make progress on the write backlog.
        if self._transport is None or self._sslpipe is None:
            return

        cdef:
            _SSLPipe sslpipe = <_SSLPipe>self._sslpipe

        try:
            for i in range(len(self._write_backlog)):
                data, offset = self._write_backlog[0]
                if data:
                    ssldata, offset = sslpipe.feed_appdata(data, offset)
                elif offset:
                    ssldata = sslpipe.do_handshake(self._on_handshake_complete)
                    offset = 1
                else:
                    ssldata = sslpipe.shutdown(self._finalize)
                    offset = 1

                self._transport.writelines(ssldata)

                if offset < len(data):
                    self._write_backlog[0] = (data, offset)
                    # A short write means that a write is blocked on a read
                    # We need to enable reading if it is paused!
                    assert sslpipe._need_ssldata
                    if self._transport._paused:
                        self._transport.resume_reading()
                    break

                # An entire chunk from the backlog was processed. We can
                # delete it and reduce the outstanding buffer size.
                del self._write_backlog[0]
                self._write_buffer_size -= len(data)
        except Exception as exc:
            if self._in_handshake:
                # Exceptions will be re-raised in _on_handshake_complete.
                self._on_handshake_complete(exc)
            else:
                self._fatal_error(exc, 'Fatal error on SSL transport')

    def _fatal_error(self, exc, message='Fatal error on transport'):
        if self._transport:
            self._transport._force_close(exc)

        if isinstance(exc, (BrokenPipeError,
                            ConnectionResetError,
                            ConnectionAbortedError)):
            if self._loop.get_debug():
                aio_logger.debug("%r: %s", self, message, exc_info=True)
        elif not isinstance(exc, aio_CancelledError):
            self._loop.call_exception_handler({
                'message': message,
                'exception': exc,
                'transport': self._transport,
                'protocol': self,
            })

    def _finalize(self):
        self._sslpipe = None

        if self._transport is not None:
            self._transport.close()

    def _abort(self):
        try:
            if self._transport is not None:
                self._transport.abort()
        finally:
            self._finalize()


cdef _feed_data_to_bufferred_proto(proto, data):
    data_len = len(data)
    while data_len:
        buf = proto.get_buffer(data_len)
        buf_len = len(buf)
        if not buf_len:
            raise RuntimeError('get_buffer() returned an empty buffer')

        if buf_len >= data_len:
            buf[:data_len] = data
            proto.buffer_updated(data_len)
            return
        else:
            buf[:buf_len] = data[:buf_len]
            proto.buffer_updated(buf_len)
            data = data[buf_len:]
            data_len = len(data)
