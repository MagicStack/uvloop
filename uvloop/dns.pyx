cdef __convert_sockaddr_to_pyaddr(system.sockaddr* addr):
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
                  str host, int port,
                  int family, int type, int proto, int flags,
                  object callback):

        cdef int err

        memset(&self.hints, 0, sizeof(system.addrinfo))
        self.hints.ai_flags = flags
        self.hints.ai_family = family
        self.hints.ai_socktype = type
        self.hints.ai_protocol = proto

        self.request = <uv.uv_req_t*> PyMem_Malloc(
            sizeof(uv.uv_getaddrinfo_t))
        if self.request is NULL:
            self.on_done()
            raise MemoryError()

        self.callback = callback
        self.request.data = <void*>self

        err = uv.uv_getaddrinfo(loop.uvloop,
                                <uv.uv_getaddrinfo_t*>self.request,
                                __on_addrinfo_resolved,
                                host.encode('utf-8'),
                                str(port).encode('latin-1'),
                                &self.hints)

        if err < 0:
            self.on_done()
            callback(convert_error(err))


cdef class NameInfoRequest(UVRequest):
    cdef:
        object callback

    def __cinit__(self, Loop loop, callback):
        self.request = <uv.uv_req_t*> PyMem_Malloc(
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
