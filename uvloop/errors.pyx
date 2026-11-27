

cdef str __strerr(int errno):
    return strerror(errno).decode()

# TODO: This Function would be a possible Candidate for moving into C.
cdef __convert_python_error(int uverr):
    cdef int oserr
    cdef object err

    if system.PLATFORM_IS_WINDOWS:
        # This has been debunked during winloop's beginnings when it was
        # still a seperate library.
        err = getattr(win_errno, uv.uv_err_name(uverr).decode(), uverr)
        return OSError(err, uv.uv_strerror(uverr).decode())

    oserr = -uverr


    exc = OSError

    if uverr in (uv.UV_EACCES, uv.UV_EPERM):
        exc = PermissionError

    elif uverr in (uv.UV_EAGAIN, uv.UV_EALREADY):
        exc = BlockingIOError

    elif uverr in (uv.UV_EPIPE, uv.UV_ESHUTDOWN):
        exc = BrokenPipeError

    elif uverr == uv.UV_ECONNABORTED:
        exc = ConnectionAbortedError

    elif uverr == uv.UV_ECONNREFUSED:
        exc = ConnectionRefusedError

    elif uverr == uv.UV_ECONNRESET:
        exc = ConnectionResetError

    elif uverr == uv.UV_EEXIST:
        exc = FileExistsError

    elif uverr == uv.UV_ENOENT:
        exc = FileNotFoundError

    elif uverr == uv.UV_EINTR:
        exc = InterruptedError

    elif uverr == uv.UV_EISDIR:
        exc = IsADirectoryError

    elif uverr == uv.UV_ESRCH:
        exc = ProcessLookupError

    elif uverr == uv.UV_ETIMEDOUT:
        exc = TimeoutError

    return exc(oserr, __strerr(oserr))


cdef int __convert_socket_error(int uverr):
    cdef int sock_err = 0

    if uverr == uv.UV_EAI_ADDRFAMILY:
        sock_err = socket_EAI_ADDRFAMILY

    elif uverr == uv.UV_EAI_AGAIN:
        sock_err = socket_EAI_AGAIN

    elif uverr == uv.UV_EAI_BADFLAGS:
        sock_err = socket_EAI_BADFLAGS

    elif uverr == uv.UV_EAI_BADHINTS:
        sock_err = socket_EAI_BADHINTS

    elif uverr == uv.UV_EAI_CANCELED:
        sock_err = socket_EAI_CANCELED

    elif uverr == uv.UV_EAI_FAIL:
        sock_err = socket_EAI_FAIL

    elif uverr == uv.UV_EAI_FAMILY:
        sock_err = socket_EAI_FAMILY

    elif uverr == uv.UV_EAI_MEMORY:
        sock_err = socket_EAI_MEMORY

    elif uverr == uv.UV_EAI_NODATA:
        sock_err = socket_EAI_NODATA

    elif uverr == uv.UV_EAI_NONAME:
        sock_err = socket_EAI_NONAME

    elif uverr == uv.UV_EAI_OVERFLOW:
        sock_err = socket_EAI_OVERFLOW

    elif uverr == uv.UV_EAI_PROTOCOL:
        sock_err = socket_EAI_PROTOCOL

    elif uverr == uv.UV_EAI_SERVICE:
        sock_err = socket_EAI_SERVICE

    elif uverr == uv.UV_EAI_SOCKTYPE:
        sock_err = socket_EAI_SOCKTYPE

    return sock_err


cdef convert_error(int uverr):
    cdef int sock_err

    if uverr == uv.UV_ECANCELED:
        return aio_CancelledError()

    sock_err = __convert_socket_error(uverr)
    if sock_err:
        # Let's keep special unicode characters from being a threat.
        # SEE: https://github.com/Vizonex/Winloop/issues/32
        msg = system.gai_strerror(sock_err).decode('utf-8', "surrogateescape")
        # Winloop comment: on Windows, cPython has a simpler error
        # message than uvlib (via winsock probably) in these two cases:
        # EAI_FAMILY [ErrNo 10047] "An address incompatible with the requested protocol was used. "
        # EAI_NONAME [ErrNo 10001] "No such host is known. "
        # We replace these messages with "getaddrinfo failed"
        if system.PLATFORM_IS_WINDOWS:
            if sock_err in (socket_EAI_FAMILY, socket_EAI_NONAME):
                msg = 'getaddrinfo failed'
        return socket_gaierror(sock_err, msg)

    return __convert_python_error(uverr)
