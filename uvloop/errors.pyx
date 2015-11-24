class LoopError(Exception):
    pass


class UVError(LoopError):
    pass


cdef convert_error(int uverr):
    cdef:
        int new_err = -1

    value = None
    msg = None

    if uverr == uv.UV_EAI_ADDRFAMILY:
        new_err = socket_EAI_ADDRFAMILY

    elif uverr == uv.UV_EAI_AGAIN:
        new_err = socket_EAI_AGAIN

    elif uverr == uv.UV_EAI_BADFLAGS:
        new_err = socket_EAI_BADFLAGS

    elif uverr == uv.UV_EAI_BADHINTS:
        new_err = socket_EAI_BADHINTS

    elif uverr == uv.UV_EAI_CANCELED:
        new_err = socket_EAI_CANCELED

    elif uverr == uv.UV_EAI_FAIL:
        new_err = socket_EAI_FAIL

    elif uverr == uv.UV_EAI_FAMILY:
        new_err = socket_EAI_FAMILY

    elif uverr == uv.UV_EAI_MEMORY:
        new_err = socket_EAI_MEMORY

    elif uverr == uv.UV_EAI_NODATA:
        new_err = socket_EAI_NODATA

    elif uverr == uv.UV_EAI_NONAME:
        new_err = socket_EAI_NONAME

    elif uverr == uv.UV_EAI_OVERFLOW:
        new_err = socket_EAI_OVERFLOW

    elif uverr == uv.UV_EAI_PROTOCOL:
        new_err = socket_EAI_PROTOCOL

    elif uverr == uv.UV_EAI_SERVICE:
        new_err = socket_EAI_SERVICE

    elif uverr == uv.UV_EAI_SOCKTYPE:
        new_err = socket_EAI_SOCKTYPE

    if new_err != -1:
        msg = system.gai_strerror(new_err).decode('utf-8')
        return socket_gaierror(new_err, msg)

    if msg is None:
        msg = uv.uv_strerror(uverr).decode('utf-8')

    if value is None:
        name = uv.uv_err_name(uverr).decode('utf-8')
        value = '({}) {}'.format(name, msg)

    return LoopError(value)
