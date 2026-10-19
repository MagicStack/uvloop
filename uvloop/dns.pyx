cdef __port_to_int(port, proto):
    if type(port) is int:
        return port

    if port is None or port == '' or port == b'':
        return 0

    try:
        return int(port)
    except (ValueError, TypeError):
        pass

    if isinstance(port, bytes):
        port = port.decode()

    if isinstance(port, str) and proto is not None:
        if proto == uv.IPPROTO_TCP:
            return socket_getservbyname(port, 'tcp')
        elif proto == uv.IPPROTO_UDP:
            return socket_getservbyname(port, 'udp')

    raise OSError('service/proto not found')


cdef __convert_sockaddr_to_pyaddr(const system.sockaddr* addr):
    # Converts sockaddr structs into what Python socket
    # module can understand:
    #   - for IPv4 a tuple of (host, port)
    #   - for IPv6 a tuple of (host, port, flowinfo, scope_id)

    cdef:
        char buf[128]  # INET6_ADDRSTRLEN is usually 46
        int err
        system.sockaddr_in *addr4
        system.sockaddr_in6 *addr6
        system.sockaddr_un *addr_un

    if addr.sa_family == uv.AF_INET:
        addr4 = <system.sockaddr_in*>addr

        err = uv.uv_ip4_name(addr4, buf, sizeof(buf))
        if err < 0:
            raise convert_error(err)

        return (
            PyUnicode_FromString(buf),
            system.ntohs(addr4.sin_port)
        )

    elif addr.sa_family == uv.AF_INET6:
        addr6 = <system.sockaddr_in6*>addr

        err = uv.uv_ip6_name(addr6, buf, sizeof(buf))
        if err < 0:
            raise convert_error(err)

        return (
            PyUnicode_FromString(buf),
            system.ntohs(addr6.sin6_port),
            system.ntohl(addr6.sin6_flowinfo),
            addr6.sin6_scope_id
        )

    elif addr.sa_family == uv.AF_UNIX:
        addr_un = <system.sockaddr_un*>addr
        return system.MakeUnixSockPyAddr(addr_un)

    raise RuntimeError("cannot convert sockaddr into Python object")


@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class SockAddrHolder:
    cdef:
        int family
        system.sockaddr_storage addr
        Py_ssize_t addr_size


cdef LruCache sockaddrs = LruCache(maxsize=DNS_PYADDR_TO_SOCKADDR_CACHE_SIZE)


cdef __convert_pyaddr_to_sockaddr(int family, object addr,
                                  system.sockaddr* res):
    cdef:
        int err
        int addr_len
        int scope_id = 0
        int flowinfo = 0
        char *buf
        Py_ssize_t buflen
        SockAddrHolder ret

    ret = sockaddrs.get(addr, None)
    if ret is not None and ret.family == family:
        memcpy(res, &ret.addr, ret.addr_size)
        return

    ret = SockAddrHolder.__new__(SockAddrHolder)
    if family == uv.AF_INET:
        if not isinstance(addr, tuple):
            raise TypeError('AF_INET address must be tuple')
        if len(addr) != 2:
            raise ValueError('AF_INET address must be tuple of (host, port)')
        host, port = addr
        if isinstance(host, str):
            try:
                # idna codec is rather slow, so we try ascii first.
                host = host.encode('ascii')
            except UnicodeEncodeError:
                host = host.encode('idna')
        if not isinstance(host, (bytes, bytearray)):
            raise TypeError('host must be a string or bytes object')

        port = __port_to_int(port, None)

        ret.addr_size = sizeof(system.sockaddr_in)
        err = uv.uv_ip4_addr(host, <int>port, <system.sockaddr_in*>&ret.addr)
        if err < 0:
            raise convert_error(err)

    elif family == uv.AF_INET6:
        if not isinstance(addr, tuple):
            raise TypeError('AF_INET6 address must be tuple')

        addr_len = len(addr)
        if addr_len < 2 or addr_len > 4:
            raise ValueError(
                'AF_INET6 must be a tuple of 2-4 parameters: '
                '(host, port, flowinfo?, scope_id?)')

        host = addr[0]
        if isinstance(host, str):
            try:
                # idna codec is rather slow, so we try ascii first.
                host = host.encode('ascii')
            except UnicodeEncodeError:
                host = host.encode('idna')
        if not isinstance(host, (bytes, bytearray)):
            raise TypeError('host must be a string or bytes object')

        port = __port_to_int(addr[1], None)

        if addr_len > 2:
            flowinfo = addr[2]
        if addr_len > 3:
            scope_id = addr[3]

        ret.addr_size = sizeof(system.sockaddr_in6)

        err = uv.uv_ip6_addr(host, port, <system.sockaddr_in6*>&ret.addr)
        if err < 0:
            raise convert_error(err)

        (<system.sockaddr_in6*>&ret.addr).sin6_flowinfo = flowinfo
        (<system.sockaddr_in6*>&ret.addr).sin6_scope_id = scope_id

    elif family == uv.AF_UNIX:
        if isinstance(addr, str):
            addr = addr.encode(sys_getfilesystemencoding())
        elif not isinstance(addr, bytes):
            raise TypeError('AF_UNIX address must be a str or a bytes object')

        PyBytes_AsStringAndSize(addr, &buf, &buflen)
        if buflen > 107:
            raise ValueError(
                f'unix socket path {addr!r} is longer than 107 characters')

        ret.addr_size = sizeof(system.sockaddr_un)
        memset(&ret.addr, 0, sizeof(system.sockaddr_un))
        (<system.sockaddr_un*>&ret.addr).sun_family = uv.AF_UNIX
        memcpy((<system.sockaddr_un*>&ret.addr).sun_path, buf, buflen)

    else:
        raise ValueError(
            f'expected AF_INET, AF_INET6, or AF_UNIX family, got {family}')

    ret.family = family
    sockaddrs[addr] = ret
    memcpy(res, &ret.addr, ret.addr_size)


cdef __static_getaddrinfo(object host, object port,
                          int family, int type,
                          int proto,
                          system.sockaddr *addr):

    if proto not in {0, uv.IPPROTO_TCP, uv.IPPROTO_UDP}:
        return

    if _is_sock_stream(type):
        proto = uv.IPPROTO_TCP
    elif _is_sock_dgram(type):
        proto = uv.IPPROTO_UDP
    else:
        return

    try:
        port = __port_to_int(port, proto)
    except Exception:
        return

    hp = (host, port)
    if family == uv.AF_UNSPEC:
        try:
            __convert_pyaddr_to_sockaddr(uv.AF_INET, hp, addr)
        except Exception:
            pass
        else:
            return (uv.AF_INET, type, proto)

        try:
            __convert_pyaddr_to_sockaddr(uv.AF_INET6, hp, addr)
        except Exception:
            pass
        else:
            return (uv.AF_INET6, type, proto)

    else:
        try:
            __convert_pyaddr_to_sockaddr(family, hp, addr)
        except Exception:
            pass
        else:
            return (family, type, proto)


cdef __static_getaddrinfo_pyaddr(object host, object port,
                                 int family, int type,
                                 int proto, int flags):

    cdef:
        system.sockaddr_storage addr
        object triplet

    triplet = __static_getaddrinfo(
        host, port, family, type,
        proto, <system.sockaddr*>&addr)
    if triplet is None:
        return

    af, type, proto = triplet

    try:
        pyaddr = __convert_sockaddr_to_pyaddr(<system.sockaddr*>&addr)
    except Exception:
        return

    # When the host is an IP while type is one of TCP or UDP, different libc
    # implementations of getaddrinfo() behave differently:
    # 1. When AI_CANONNAME is set:
    #    * glibc: returns ai_canonname
    #    * musl: returns ai_canonname
    #    * macOS: returns an empty string for ai_canonname
    # 2. When AI_CANONNAME is NOT set:
    #    * glibc: returns an empty string for ai_canonname
    #    * musl: returns ai_canonname
    #    * macOS: returns an empty string for ai_canonname
    # At the same time, libuv and CPython both uses libc directly, even though
    # this different behavior is violating what is in the documentation.
    #
    # uvloop potentially should be a 100% drop-in replacement for asyncio,
    # doing whatever asyncio does, especially when the libc implementations are
    # also different in the same way. However, making our implementation to be
    # consistent with libc/CPython would be complex and hard to maintain
    # (including caching libc behaviors when flag is/not set), therefore we
    # decided to simply normalize the behavior in uvloop for this very marginal
    # case following the documentation, even though uvloop would behave
    # differently to asyncio on macOS and musl platforms, when again the host
    # is an IP and type is one of TCP or UDP.
    # All other cases are still asyncio-compatible.
    if flags & socket_AI_CANONNAME:
        if isinstance(host, str):
            canon_name = host
        else:
            canon_name = host.decode('ascii')
    else:
        canon_name = ''

    return (
        _intenum_converter(af, socket_AddressFamily),
        _intenum_converter(type, socket_SocketKind),
        proto,
        canon_name,
        pyaddr,
    )


@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class AddrInfo:
    cdef:
        system.addrinfo *data

    def __cinit__(self):
        self.data = NULL

    def __dealloc__(self):
        if self.data is not NULL:
            uv.uv_freeaddrinfo(self.data)  # returns void
            self.data = NULL

    cdef void set_data(self, system.addrinfo *data) noexcept:
        self.data = data

    cdef unpack(self):
        cdef:
            list result = []
            system.addrinfo *ptr

        if self.data is NULL:
            raise RuntimeError('AddrInfo.data is NULL')

        ptr = self.data
        while ptr != NULL:
            if ptr.ai_addr.sa_family in (uv.AF_INET, uv.AF_INET6):
                result.append((
                    _intenum_converter(ptr.ai_family, socket_AddressFamily),
                    _intenum_converter(ptr.ai_socktype, socket_SocketKind),
                    ptr.ai_protocol,
                    ('' if ptr.ai_canonname is NULL else
                        (<bytes>ptr.ai_canonname).decode()),
                    __convert_sockaddr_to_pyaddr(ptr.ai_addr)
                ))

            ptr = ptr.ai_next

        return result

    @staticmethod
    cdef int isinstance(object other):
        return type(other) is AddrInfo


def _getaddrinfo_worker(bytes host, bytes port, int family, int type,
                         int proto, int flags, int unpack):
    cdef:
        uv.uv_getaddrinfo_t request
        system.addrinfo hints
        const char *chost = NULL
        const char *cport = NULL
        int err
        AddrInfo result = AddrInfo()

    if host is not None:
        if host == b'' and sys.platform == 'darwin':
            host = b'localhost'
        chost = host
    if port is not None:
        cport = port

    memset(&hints, 0, sizeof(hints))
    hints.ai_flags = flags
    hints.ai_family = family
    hints.ai_socktype = type
    hints.ai_protocol = proto

    # Synchronous libuv resolution owns no request on the event loop. The
    # executor keeps this stack and the input bytes alive until it completes.
    with nogil:
        err = uv.uv_getaddrinfo(NULL, &request, NULL, chost, cport, &hints)
    if err < 0:
        if err == uv.UV_EINVAL:
            msg = system.gai_strerror(socket_EAI_NONAME).decode('utf-8')
            raise socket_gaierror(socket_EAI_NONAME, msg)
        raise convert_error(err)

    result.set_data(request.addrinfo)
    if unpack:
        return result.unpack()
    return result


def _getnameinfo_worker(SockAddrHolder holder, int flags):
    cdef:
        uv.uv_loop_t resolver_loop
        uv.uv_getnameinfo_t request
        int err
        int close_err

    # Unlike uv_getaddrinfo, libuv's synchronous uv_getnameinfo still
    # registers its request on a loop. Use a worker-owned loop so it never
    # touches the application loop, even when that loop has been closed.
    with nogil:
        err = uv.uv_loop_init(&resolver_loop)
    if err < 0:
        raise convert_error(err)
    with nogil:
        err = uv.uv_getnameinfo(
            &resolver_loop, &request, NULL,
            <system.sockaddr*>&holder.addr, flags)
        close_err = uv.uv_loop_close(&resolver_loop)
    if err < 0:
        raise convert_error(err)
    if close_err < 0:
        raise convert_error(close_err)
    return ((<bytes>request.host).decode(), (<bytes>request.service).decode())


cdef _intenum_converter(value, enum_klass):
    try:
        return enum_klass(value)
    except ValueError:
        return value
