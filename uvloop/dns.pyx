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
            system.addrinfo *ptr
            system.sockaddr_in *addr4
            system.sockaddr_in6 *addr6
            char buf[92] # INET6_ADDRSTRLEN is usually 46
            int err
            list result = []

        if self.data is NULL:
            raise RuntimeError('AddrInfo.data is NULL')

        ptr = self.data
        while ptr != NULL:
            if ptr.ai_addr.sa_family == uv.AF_INET:
                addr4 = <system.sockaddr_in*> ptr.ai_addr
                err = uv.uv_ip4_name(addr4, buf, sizeof(buf))
                if err < 0:
                    raise convert_error(err)

                result.append((
                    ptr.ai_family,
                    ptr.ai_socktype,
                    ptr.ai_protocol,
                    '' if ptr.ai_canonname is NULL else
                        (<bytes>ptr.ai_canonname).decode(),
                    (
                        (<bytes>buf).decode(),
                        uv.ntohs(addr4.sin_port)
                    )
                ))

            elif ptr.ai_addr.sa_family == uv.AF_INET6:
                addr6 = <system.sockaddr_in6*> ptr.ai_addr
                err = uv.uv_ip6_name(addr6, buf, sizeof(buf))
                if err < 0:
                    raise convert_error(err)

                result.append((
                    ptr.ai_family,
                    ptr.ai_socktype,
                    ptr.ai_protocol,
                    '' if ptr.ai_canonname is NULL else
                        (<bytes>ptr.ai_canonname).decode(),
                    (
                        (<bytes>buf).decode(),
                        uv.ntohs(addr6.sin6_port),
                        uv.ntohl(addr6.sin6_flowinfo),
                        addr6.sin6_scope_id
                    )
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
        # We no longer need our AddrInfoRequest wrapper -- on_done()
        # will untrack it in the loop, and it will be garbage
        # collected soon.
        request.on_done()

        if status < 0:
            callback(convert_error(status))
        else:
            ai = AddrInfo()
            ai.set_data(res)
            callback(ai)
    except Exception as ex:
        loop._handle_exception(ex)
