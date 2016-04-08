@cython.no_gc_clear
cdef class UVProcess(UVHandle):
    """Abstract class; wrapper over uv_process_t handle."""

    def __cinit__(self):
        self.uv_opt_env = NULL
        self.uv_opt_args = NULL
        self._returncode = None

    cdef _init(self, Loop loop, list args, dict env,
               cwd, start_new_session,
               stdin, stdout, stderr):

        cdef int err

        self._start_init(loop)

        self._handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_process_t))
        if self._handle is NULL:
            self._abort_init()
            raise MemoryError()

        try:
            self._init_options(args, env, cwd, start_new_session,
                               stdin, stdout, stderr)
        except:
            self._abort_init()
            raise

        err = uv.uv_spawn(loop.uvloop,
                          <uv.uv_process_t*>self._handle,
                          &self.options)
        if err < 0:
            self._abort_init()
            raise convert_error(err)

        self._finish_init()

    cdef _free(self):
        if self.uv_opt_env is not NULL:
            PyMem_Free(self.uv_opt_env)
            self.uv_opt_env = NULL

        if self.uv_opt_args is not NULL:
            PyMem_Free(self.uv_opt_args)
            self.uv_opt_args = NULL

        UVHandle._free(self)

    cdef char** __to_cstring_array(self, list arr):
        cdef:
            int i
            int arr_len = len(arr)
            bytes el

            char **ret

        IF DEBUG:
            assert arr_len > 0

        ret = <char **>PyMem_Malloc((arr_len + 1) * sizeof(char *))
        if ret is NULL:
            raise MemoryError()

        for i in range(arr_len):
            el = arr[i]
            # NB: PyBytes_AsSptring doesn't copy the data;
            # we have to be careful when the "arr" is GCed,
            # and it shouldn't be ever mutated.
            ret[i] = PyBytes_AsString(el)

        ret[arr_len] = NULL
        return ret

    cdef _init_options(self, list args, dict env, cwd, start_new_session,
                       stdin, stdout, stderr):

        memset(&self.options, 0, sizeof(uv.uv_process_options_t))

        self._init_env(env)
        self.options.env = self.uv_opt_env

        self._init_args(args)
        self.options.file = self.uv_opt_file
        self.options.args = self.uv_opt_args

        if start_new_session:
            self.options.flags |= uv.UV_PROCESS_DETACHED

        if cwd is not None:
            if isinstance(cwd, str):
                cwd = cwd.encode(sys_fs_encoding)
            if not isinstance(cwd, bytes):
                raise ValueError('cwd must be a str or bytes object')
            self.__cwd = cwd
            self.options.cwd = PyBytes_AsString(self.__cwd)

        self.options.exit_cb = &__uvprocess_on_exit_callback

        self._init_files(stdin, stdout, stderr)

    cdef _init_args(self, list args):
        cdef:
            bytes path
            int an = len(args)

        if an < 1:
            raise ValueError('cannot spawn a process: args are empty')

        self.__args = args.copy()
        for i in range(an):
            arg = args[i]
            if isinstance(arg, str):
                self.__args[i] = arg.encode(sys_fs_encoding)
            elif not isinstance(arg, bytes):
                raise TypeError('all args must be str or bytes')

        path = self.__args[0]
        self.uv_opt_file = PyBytes_AsString(path)
        self.uv_opt_args = self.__to_cstring_array(self.__args)

    cdef _init_env(self, dict env):
        if env is not None and len(env):
            self.__env = list()
            for key in env:
                val = env[key]

                if isinstance(key, str):
                    key = key.encode(sys_fs_encoding)
                elif not isinstance(key, bytes):
                    raise TypeError(
                        'all environment vars must be bytes or str')

                if isinstance(val, str):
                    val = val.encode(sys_fs_encoding)
                elif not isinstance(val, bytes):
                    raise TypeError(
                        'all environment values must be bytes or str')

                self.__env.append(key + b'=' + val)

            self.uv_opt_env = self.__to_cstring_array(self.__env)
        else:
            self.__env = None

    cdef _init_files(self, stdin, stdout, stderr):
        self.iocnt[0].flags = uv.UV_IGNORE
        self.iocnt[1].flags = uv.UV_IGNORE
        self.iocnt[2].flags = uv.UV_IGNORE
        self.options.stdio_count = 3
        self.options.stdio = self.iocnt

    cdef _kill(self, int signum):
        cdef int err
        self._ensure_alive()
        err = uv.uv_process_kill(<uv.uv_process_t*>self._handle, signum)
        if err < 0:
            raise convert_error(err)

    cdef _on_exit(self, int64_t exit_status, int term_signal):
        self._returncode = exit_status
        self._close()


@cython.no_gc_clear
cdef class UVProcessTransport(UVProcess):
    def __cinit__(self):
        self._exit_waiters = []
        self._protocol = None

    cdef _on_exit(self, int64_t exit_status, int term_signal):
        UVProcess._on_exit(self, exit_status, term_signal)

        for waiter in self._exit_waiters:
            if not waiter.cancelled():
                waiter.set_result(exit_status)
        self._exit_waiters.clear()

    cdef _check_proc(self):
        if not self._is_alive() or self._returncode is not None:
            raise ProcessLookupError()

    cdef _pipe_connection_lost(self, int fd, exc):
        self._loop.call_soon(self._protocol.pipe_connection_lost, fd, exc)

    cdef _pipe_data_received(self, int fd, data):
        self._loop.call_soon(self._protocol.pipe_data_received, fd, data)

    cdef _init_files(self, stdin, stdout, stderr):
        UVProcess._init_files(self, stdin, stdout, stderr)

        self.stdin = self.stdout = self.stderr = None

        if stdin is not None:
            if stdin == subprocess_PIPE:
                proto = WriteSubprocessPipeProto(self, 0)
                self.stdin = UVWritePipeTransport.new(self._loop, proto, None)

                io = &self.iocnt[0]
                io.flags = <uv.uv_stdio_flags>(uv.UV_CREATE_PIPE |
                                               uv.UV_WRITABLE_PIPE)
                io.data.stream = <uv.uv_stream_t*>self.stdin._handle
            else:
                raise NotImplementedError

        if stdout is not None:
            if stdout == subprocess_PIPE:
                proto = ReadSubprocessPipeProto(self, 1)
                self.stdout = UVReadPipeTransport.new(self._loop, proto, None)

                io = &self.iocnt[1]
                io.flags = <uv.uv_stdio_flags>(uv.UV_CREATE_PIPE |
                                               uv.UV_READABLE_PIPE)
                io.data.stream = <uv.uv_stream_t*>self.stdout._handle
            else:
                raise NotImplementedError

        if stderr is not None:
            if stderr == subprocess_PIPE:
                proto = ReadSubprocessPipeProto(self, 2)
                self.stderr = UVReadPipeTransport.new(self._loop, proto, None)

                io = &self.iocnt[2]
                io.flags = <uv.uv_stdio_flags>(uv.UV_CREATE_PIPE |
                                               uv.UV_READABLE_PIPE)
                io.data.stream = <uv.uv_stream_t*>self.stderr._handle
            else:
                raise NotImplementedError


    @staticmethod
    cdef UVProcessTransport new(Loop loop, protocol, args, env,
                                cwd, start_new_session,
                                stdin, stdout, stderr,
                                waiter):

        cdef UVProcessTransport handle
        handle = UVProcessTransport.__new__(UVProcessTransport)
        handle._protocol = protocol
        handle._init(loop, args, env, cwd, start_new_session,
                     __process_convert_fileno(stdin),
                     __process_convert_fileno(stdout),
                     __process_convert_fileno(stderr))

        if handle.stdin is not None:
            handle.stdin._schedule_call_connection_made()
        if handle.stdout is not None:
            handle.stdout._schedule_call_connection_made()
        if handle.stderr is not None:
            handle.stderr._schedule_call_connection_made()

        loop.call_soon(protocol.connection_made, handle)
        if waiter is not None:
            loop.call_soon(_set_result_unless_cancelled, waiter, True)

        return handle

    def get_pid(self):
        self._ensure_alive()
        return (<uv.uv_process_t*>self._handle).pid

    def get_returncode(self):
        return self._returncode

    def get_pipe_transport(self, fd):
        if fd == 0:
            return self.stdin
        elif fd == 1:
            return self.stdout
        elif fd == 2:
            return self.stderr

    def terminate(self):
        self._check_proc()
        self._kill(uv.SIGTERM)

    def kill(self):
        self._check_proc()
        self._kill(uv.SIGKILL)

    def send_signal(self, int signal):
        self._check_proc()
        self._kill(signal)

    def is_closing(self):
        return self._closed

    def close(self):
        if self._returncode is None:
            self._kill(uv.SIGKILL)

        self._close()

    def _wait(self):
        fut = aio_Future(loop=self._loop)
        if self._returncode is not None:
            fut.set_result(self._returncode)
            return fut

        self._exit_waiters.append(fut)
        return fut


class WriteSubprocessPipeProto(aio_BaseProtocol):

    def __init__(self, proc, fd):
        IF DEBUG:
            if type(proc) is not UVProcessTransport:
                raise TypeError
            if not isinstance(fd, int):
                raise TypeError
        self.proc = proc
        self.fd = fd
        self.pipe = None
        self.disconnected = False

    def connection_made(self, transport):
        self.pipe = transport

    def __repr__(self):
        return ('<%s fd=%s pipe=%r>'
                % (self.__class__.__name__, self.fd, self.pipe))

    def connection_lost(self, exc):
        self.disconnected = True
        (<UVProcessTransport>self.proc)._pipe_connection_lost(self.fd, exc)
        self.proc = None

    def pause_writing(self):
        (<UVProcessTransport>self.proc)._protocol.pause_writing()

    def resume_writing(self):
        (<UVProcessTransport>self.proc)._protocol.resume_writing()


class ReadSubprocessPipeProto(WriteSubprocessPipeProto,
                              aio_Protocol):

    def data_received(self, data):
        (<UVProcessTransport>self.proc)._pipe_data_received(self.fd, data)


cdef __process_convert_fileno(object obj):
    if obj is None or isinstance(obj, int):
        return obj

    fileno = obj.fileno()
    if not isinstance(fileno, int):
        raise TypeError(
            '{!r}.fileno() returned non-integer'.format(obj))
    return fileno


cdef void __uvprocess_on_exit_callback(uv.uv_process_t *handle,
                                       int64_t exit_status,
                                       int term_signal) with gil:

    if __ensure_handle_data(<uv.uv_handle_t*>handle,
                            "UVProcess exit callback") == 0:
        return

    cdef UVProcess proc = <UVProcess> handle.data
    try:
        proc._on_exit(exit_status, term_signal)
    except BaseException as ex:
        proc._error(ex, False)
