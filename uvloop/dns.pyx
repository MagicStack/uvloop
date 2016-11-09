cdef __port_to_int(port, proto):
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

    if addr.sa_family == uv.AF_INET:
        addr4 = <system.sockaddr_in*>addr

        err = uv.uv_ip4_name(addr4, buf, sizeof(buf))
        if err < 0:
            raise convert_error(err)

        return (
            (<bytes>buf).decode(),
            system.ntohs(addr4.sin_port)
        )

    elif addr.sa_family == uv.AF_INET6:
        addr6 = <system.sockaddr_in6*>addr

        err = uv.uv_ip6_name(addr6, buf, sizeof(buf))
        if err < 0:
            raise convert_error(err)

        return (
            (<bytes>buf).decode(),
            system.ntohs(addr6.sin6_port),
            system.ntohl(addr6.sin6_flowinfo),
            addr6.sin6_scope_id
        )

    raise RuntimeError("cannot convert sockaddr into Python object")


cdef __convert_pyaddr_to_sockaddr(int family, object addr,
                                  system.sockaddr* res):
    cdef:
        int err
        int addr_len
        int scope_id = 0
        int flowinfo = 0

    if family == uv.AF_INET:
        if not isinstance(addr, tuple):
            raise TypeError('AF_INET address must be tuple')
        if len(addr) != 2:
            raise ValueError('AF_INET address must be tuple of (host, port)')
        host, port = addr
        if isinstance(host, str):
            host = host.encode('idna')
        if not isinstance(host, (bytes, bytearray)):
            raise TypeError('host must be a string or bytes object')

        port = __port_to_int(port, None)

        err = uv.uv_ip4_addr(host, <int>port, <system.sockaddr_in*>res)
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
            host = host.encode('idna')

        port = __port_to_int(addr[1], None)

        if addr_len > 2:
            flowinfo = addr[2]
        if addr_len > 3:
            scope_id = addr[3]

        err = uv.uv_ip6_addr(host, port, <system.sockaddr_in6*>res)
        if err < 0:
            raise convert_error(err)

        (<system.sockaddr_in6*>res).sin6_flowinfo = flowinfo
        (<system.sockaddr_in6*>res).sin6_scope_id = scope_id

    else:
        raise ValueError(
            'epected AF_INET or AF_INET6 family, got {}'.format(family))


cdef __static_getaddrinfo(object host, object port,
                          int family, int type,
                          int proto,
                          system.sockaddr *addr):

    if proto not in {0, uv.IPPROTO_TCP, uv.IPPROTO_UDP}:
        raise LookupError

    if type == uv.SOCK_STREAM:
        # Linux only:
        #    getaddrinfo() can raise when socket.type is a bit mask.
        #    So if socket.type is a bit mask of SOCK_STREAM, and say
        #    SOCK_NONBLOCK, we simply return None, which will trigger
        #    a call to getaddrinfo() letting it process this request.
        proto = uv.IPPROTO_TCP
    elif type == uv.SOCK_DGRAM:
        proto = uv.IPPROTO_UDP
    else:
        raise LookupError

    try:
        port = __port_to_int(port, proto)
    except:
        raise LookupError

    if family == uv.AF_UNSPEC:
        afs = [uv.AF_INET, uv.AF_INET6]
    else:
        afs = [family]

    for af in afs:
        try:
            __convert_pyaddr_to_sockaddr(af, (host, port), addr)
        except:
            continue
        else:
            return (af, type, proto)

    raise LookupError


cdef __static_getaddrinfo_pyaddr(object host, object port,
                                 int family, int type,
                                 int proto, int flags):

    cdef:
        system.sockaddr_storage addr

    try:
        (af, type, proto) = __static_getaddrinfo(
            host, port, family, type,
            proto, <system.sockaddr*>&addr)
    except LookupError:
        return

    try:
        pyaddr = __convert_sockaddr_to_pyaddr(<system.sockaddr*>&addr)
    except:
        return

    return af, type, proto, '', pyaddr


@cython.freelist(DEFAULT_FREELIST_SIZE)
cdef class AddrInfo:
    cdef:
        system.addrinfo *data

    def __cinit__(self):
        self.data = NULL

    def __dealloc__(self):
        if self.data is not NULL:
            uv.uv_freeaddrinfo(self.data) # returns void
            self.data = NULL

    cdef void set_data(self, system.addrinfo *data):
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
                    ptr.ai_family,
                    ptr.ai_socktype,
                    ptr.ai_protocol,
                    '' if ptr.ai_canonname is NULL else
                        (<bytes>ptr.ai_canonname).decode(),
                    __convert_sockaddr_to_pyaddr(ptr.ai_addr)
                ))

            ptr = ptr.ai_next

        return result

    @staticmethod
    cdef int isinstance(object other):
        return type(other) is AddrInfo


cdef class AddrInfoRequest(UVRequest):
    cdef:
        system.addrinfo hints
        object callback

    def __cinit__(self, Loop loop,
                  bytes host, bytes port,
                  int family, int type, int proto, int flags,
                  object callback):

        cdef:
            int err
            char *chost
            char *cport

        if host is None:
            chost = NULL
        else:
            chost = <char*>host

        if port is None:
            cport = NULL
        else:
            cport = <char*>port

        if cport is NULL and chost is NULL:
            self.on_done()
            msg = system.gai_strerror(socket_EAI_NONAME).decode('utf-8')
            ex = socket_gaierror(socket_EAI_NONAME, msg)
            callback(ex)
            return

        memset(&self.hints, 0, sizeof(system.addrinfo))
        self.hints.ai_flags = flags
        self.hints.ai_family = family
        self.hints.ai_socktype = type
        self.hints.ai_protocol = proto

        self.request = <uv.uv_req_t*> PyMem_RawMalloc(
            sizeof(uv.uv_getaddrinfo_t))
        if self.request is NULL:
            self.on_done()
            raise MemoryError()

        self.callback = callback
        self.request.data = <void*>self

        err = uv.uv_getaddrinfo(loop.uvloop,
                                <uv.uv_getaddrinfo_t*>self.request,
                                __on_addrinfo_resolved,
                                chost,
                                cport,
                                &self.hints)

        if err < 0:
            self.on_done()
            callback(convert_error(err))


cdef class NameInfoRequest(UVRequest):
    cdef:
        object callback

    def __cinit__(self, Loop loop, callback):
        self.request = <uv.uv_req_t*> PyMem_RawMalloc(
            sizeof(uv.uv_getnameinfo_t))
        if self.request is NULL:
            self.on_done()
            raise MemoryError()

        self.callback = callback
        self.request.data = <void*>self

    cdef query(self, system.sockaddr *addr, int flags):
        cdef int err
        err = uv.uv_getnameinfo(self.loop.uvloop,
                                <uv.uv_getnameinfo_t*>self.request,
                                __on_nameinfo_resolved,
                                addr,
                                flags)
        if err < 0:
            self.on_done()
            self.callback(convert_error(err))


cdef void __on_addrinfo_resolved(uv.uv_getaddrinfo_t *resolver,
                                 int status, system.addrinfo *res) with gil:

    if resolver.data is NULL:
        aio_logger.error(
            'AddrInfoRequest callback called with NULL resolver.data')
        return

    cdef:
        AddrInfoRequest request = <AddrInfoRequest> resolver.data
        Loop loop = request.loop
        object callback = request.callback
        AddrInfo ai

    try:
        if status < 0:
            callback(convert_error(status))
        else:
            ai = AddrInfo()
            ai.set_data(res)
            callback(ai)
    except Exception as ex:
        loop._handle_exception(ex)
    finally:
        request.on_done()


cdef void __on_nameinfo_resolved(uv.uv_getnameinfo_t* req,
                                 int status,
                                 const char* hostname,
                                 const char* service) with gil:
    cdef:
        NameInfoRequest request = <NameInfoRequest> req.data
        Loop loop = request.loop
        object callback = request.callback

    try:
        if status < 0:
            callback(convert_error(status))
        else:
            callback(((<bytes>hostname).decode(),
                      (<bytes>service).decode()))
    except Exception as ex:
        loop._handle_exception(ex)
    finally:
        request.on_done()
