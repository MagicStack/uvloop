from libc.stdint cimport int8_t, uint64_t

cdef extern from "includes/system.h":
    int ntohl(int) nogil
    int htonl(int) nogil
    int ntohs(int) nogil

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

    struct sockaddr_un :
        unsigned short sun_family
        char           sun_path[108]
    # ...

    const char* gai_strerror(int errcode) nogil

    int socketpair(int domain, int type, int protocol, int socket_vector[2]) nogil

    int setsockopt(int socket, int level, int option_name, const void* option_value, int option_len) nogil

    ssize_t write(int fd, const void *buf, size_t count) nogil
    void _exit(int status) nogil

    int pthread_atfork (
            void (*prepare)(),
            void (*parent)(),
            void (*child)())



cdef extern from "includes/compat.h" nogil:

    cdef int EWOULDBLOCK

    cdef int PLATFORM_IS_APPLE
    cdef int PLATFORM_IS_LINUX
    cdef int PLATFORM_IS_WINDOWS

    struct epoll_event:
        # We don't use the fields
        pass

    int EPOLL_CTL_DEL
    int epoll_ctl(int epfd, int op, int fd, epoll_event *event)
    object MakeUnixSockPyAddr(sockaddr_un *addr)
    void DebugBreak()
    void DbgBreak()
    void stdio_container_init(void *pipe, int fd)
    void process_init(void *process)
    void CloseIOCP(void* loop)
    void PrintAllHandle(void* loop)
    int create_tcp_socket()


cdef extern from "includes/fork_handler.h":

    uint64_t MAIN_THREAD_ID
    int8_t MAIN_THREAD_ID_SET
    ctypedef void (*OnForkHandler)()
    void handleAtFork()
    void setForkHandler(OnForkHandler handler)
    void resetForkHandler()
    void setMainThreadID(uint64_t id)
