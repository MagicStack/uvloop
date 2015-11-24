class LoopError(Exception):
    pass


class UVError(LoopError):
    pass


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
        msg = system.gai_strerror(sock_err).decode('utf-8')
        return socket_gaierror(sock_err, msg)

    msg = uv.uv_strerror(uverr).decode('utf-8')
    name = uv.uv_err_name(uverr).decode('utf-8')
    value = '({}) {}'.format(name, msg)
    return LoopError(value)
