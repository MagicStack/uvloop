cdef extern from "arpa/inet.h" nogil:

    int ntohl(int)
    int htonl(int)
    int ntohs(int)


cdef extern from "sys/socket.h" nogil:

    struct sockaddr:
        unsigned short sa_family
        char           sa_data[14]

    struct addrinfo:
        int            ai_flags
        int            ai_family
        int            ai_socktype
        int            ai_protocol
        size_t         ai_addrlen
        sockaddr*      ai_addr
        char*          ai_canonname
        addrinfo*      ai_next

    struct sockaddr_in:
        unsigned short sin_family
        unsigned short sin_port
        # ...

    struct sockaddr_in6:
        unsigned short sin6_family
        unsigned short sin6_port
        unsigned long  sin6_flowinfo
        # ...
        unsigned long  sin6_scope_id

    struct sockaddr_storage:
        unsigned short ss_family
        # ...

    const char *gai_strerror(int errcode)

    int socketpair(int domain, int type, int protocol, int socket_vector[2])

    int setsockopt(int socket, int level, int option_name,
                   const void *option_value, int option_len)


cdef extern from "unistd.h" nogil:

    ssize_t write(int fd, const void *buf, size_t count)
    void _exit(int status)


cdef extern from "pthread.h" nogil:

    int pthread_atfork(
        void (*prepare)() nogil,
        void (*parent)() nogil,
        void (*child)() nogil)


cdef extern from "includes/compat.h" nogil:

    cdef int EWOULDBLOCK

    cdef int PLATFORM_IS_APPLE
    cdef int PLATFORM_IS_LINUX

    struct epoll_event:
        # We don't use the fields
        pass

    int EPOLL_CTL_DEL
    int epoll_ctl(int epfd, int op, int fd, epoll_event *event)
