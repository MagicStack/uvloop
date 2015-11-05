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


# async def loop_create_server(Loop loop,
#                              protocol_factory,
#                              host=None, port=None,
#                              family=uv.AF_UNSPEC,
#                              flags=uv.AI_PASSIVE,
#                              sock=None,
#                              backlog=100,
#                              ssl=None,
#                              reuse_address=None,
#                              reuse_port=None):

#     if ssl:
#         raise RuntimeError('ssl is not supported')

#     if host is not None or port is not None:
#         if sock is not None:
#             raise ValueError(
#                 'host/port and sock can not be specified at the same time')

#         if reuse_address is None:
#             reuse_address = os_name == 'posix' and sys_platform != 'cygwin'

#         sockets = []
#         if host == '':
#             hosts = [None]
#         elif (isinstance(host, str) or
#               not isinstance(host, collections.Iterable)):
#             hosts = [host]
#         else:
#             hosts = host

#         fs = [loop.getaddrinfo(host, port, family=family, flags=flags)
#               for host in hosts]
#         infos = await aio_gather(*fs, loop=self)
#         infos = itertools.chain.from_iterable(infos)

#         completed = False
#         try:
#             for res in infos:
#                 if not res:
#                     continue

#                 af, socktype, proto, canonname, sa = res
#                 try:
#                     sock = socket.socket(af, socktype, proto)
#                 except socket.error:
#                     # Assume it's a bad family/type/protocol combination.
#                     if self._debug:
#                         logger.warning('create_server() failed to create '
#                                        'socket.socket(%r, %r, %r)',
#                                        af, socktype, proto, exc_info=True)
#                     continue
#                 sockets.append(sock)
#                 if reuse_address:
#                     sock.setsockopt(
#                         socket.SOL_SOCKET, socket.SO_REUSEADDR, True)
#                 if reuse_port:
#                     if not hasattr(socket, 'SO_REUSEPORT'):
#                         raise ValueError(
#                             'reuse_port not supported by socket module')
#                     else:
#                         sock.setsockopt(
#                             socket.SOL_SOCKET, socket.SO_REUSEPORT, True)
#                 # Disable IPv4/IPv6 dual stack support (enabled by
#                 # default on Linux) which makes a single socket
#                 # listen on both address families.
#                 if has_AF_INET6 and has_IPPROTO_IPV6 and af == uv.AF_INET6:
#                     sock.setsockopt(uv.IPPROTO_IPV6, uv.IPV6_V6ONLY, True)
#                 try:
#                     sock.bind(sa)
#                 except OSError as err:
#                     raise OSError(err.errno, 'error while attempting '
#                                   'to bind on address %r: %s'
#                                   % (sa, err.strerror.lower()))
#             completed = True
#         finally:
#             if not completed:
#                 for sock in sockets:
#                     sock.close()
#     else:
#         if sock is None:
#             raise ValueError('Neither host/port nor sock were specified')
#         sockets = [sock]
