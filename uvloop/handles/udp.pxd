cdef class UDPTransport(UVBaseTransport):
    cdef:
        bint __receiving
        int _family

    cdef _init(self, Loop loop, unsigned int family)

    cdef _connect(self, system.sockaddr* addr, size_t addr_len)

    cdef _bind(self, system.sockaddr* addr, bint reuse_addr)
    cdef open(self, int family, int sockfd)
    cdef _set_broadcast(self, bint on)

    cdef inline __receiving_started(self)
    cdef inline __receiving_stopped(self)

    cdef _send(self, object data, object addr)

    cdef _on_receive(self, bytes data, object exc, object addr)
    cdef _on_sent(self, object exc)
