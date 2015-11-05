@cython.freelist(50)
cdef class AddrInfo:
    cdef:
        uv.addrinfo *data

    def __cinit__(self):
        self.data = NULL

    def __dealloc__(self):
        if self.data is not NULL:
            uv.uv_freeaddrinfo(self.data) # returns void
            self.data = NULL

    cdef set_data(self, uv.addrinfo *data):
        self.data = data

    cdef unpack(self):
        cdef:
            uv.addrinfo *ptr
            uv.sockaddr_in *addr4
            uv.sockaddr_in6 *addr6
            char buf[92] # INET6_ADDRSTRLEN is usually 46
            int err
            list result = []

        if self.data is NULL:
            raise RuntimeError('AddrInfo.data is NULL')

        ptr = self.data
        while ptr != NULL:
            if ptr.ai_addr.sa_family == uv.AF_INET:
                addr4 = <uv.sockaddr_in*> ptr.ai_addr
                err = uv.uv_ip4_name(addr4, buf, sizeof(buf))
                if err < 0:
                    raise get_uverror(err)

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
                addr6 = <uv.sockaddr_in6*> ptr.ai_addr
                err = uv.uv_ip6_name(addr6, buf, sizeof(buf))
                if err < 0:
                    raise get_uverror(err)

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


cdef getaddrinfo(Loop loop,
                 str host, int port,
                 int family, int type, int proto, int flags,
                 object callback):

    cdef:
        uv.addrinfo hints
        uv.uv_getaddrinfo_t* resolver
        int err

    memset(&hints, 0, sizeof(uv.addrinfo))
    hints.ai_flags = flags
    hints.ai_family = family
    hints.ai_socktype = type
    hints.ai_protocol = proto

    resolver = <uv.uv_getaddrinfo_t*> PyMem_Malloc(sizeof(uv.uv_getaddrinfo_t))
    if resolver is NULL:
        raise MemoryError()

    resolver.data = <void*>callback

    err = uv.uv_getaddrinfo(loop.loop,
                            resolver,
                            __on_getaddr_resolved,
                            host.encode('utf-8'),
                            str(port).encode('latin-1'),
                            &hints)

    if err < 0:
        PyMem_Free(resolver)
        loop._handle_uv_error(err)
    else:
        # 'callback' must stay alive until on_getaddr_resolved
        Py_INCREF(callback)


cdef void __on_getaddr_resolved(uv.uv_getaddrinfo_t *resolver,
                                int status, uv.addrinfo *res):

    cdef:
        callback = <object> resolver.data
        AddrInfo ai

    try:
        if status == uv.UV_ECANCELED:
            callback(aio_CancelledError())
        else:
            if status < 0:
                callback(get_uverror(status))
            else:
                ai = AddrInfo()
                ai.set_data(res)
                callback(ai)

    finally:
        PyMem_Free(resolver)
        Py_DECREF(callback)
