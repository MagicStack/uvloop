@cython.no_gc_clear
cdef class UVProcess(UVHandle):
    """Abstract class; wrapper over uv_process_t handle."""

    def __cinit__(self):
        self.uv_opt_env = NULL
        self.uv_opt_args = NULL
        self._returncode = None
        self._fds_to_close = set()

    cdef _init(self, Loop loop, list args, dict env,
               cwd, start_new_session,
               stdin, stdout, stderr, pass_fds):

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

            restore_inheritable = set()
            if pass_fds:
                for fd in pass_fds:
                    if not os_get_inheritable(fd):
                        restore_inheritable.add(fd)
                        os_set_inheritable(fd, True)
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

        for fd in restore_inheritable:
            os_set_inheritable(fd, False)

        fds_to_close = self._fds_to_close
        self._fds_to_close = None
        for fd in fds_to_close:
            os_close(fd)

    cdef _close_after_spawn(self, int fd):
        if self._fds_to_close is None:
            raise RuntimeError(
                'UVProcess._close_after_spawn called after uv_spawn')
        self._fds_to_close.add(fd)

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
        self.options.stdio_count = 0

    cdef _kill(self, int signum):
        cdef int err
        self._ensure_alive()
        err = uv.uv_process_kill(<uv.uv_process_t*>self._handle, signum)
        if err < 0:
            raise convert_error(err)

    cdef _on_exit(self, int64_t exit_status, int term_signal):
        if term_signal:
            # From Python docs:
            #    A negative value -N indicates that the child was
            #    terminated by signal N (POSIX only).
            self._returncode = -term_signal
        else:
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
                waiter.set_result(self._returncode)
        self._exit_waiters.clear()

    cdef _check_proc(self):
        if not self._is_alive() or self._returncode is not None:
            raise ProcessLookupError()

    cdef _pipe_connection_lost(self, int fd, exc):
        self._loop.call_soon(self._protocol.pipe_connection_lost, fd, exc)

    cdef _pipe_data_received(self, int fd, data):
        self._loop.call_soon(self._protocol.pipe_data_received, fd, data)

    cdef _file_redirect_stdio(self, int fd):
        fd = os_dup(fd)
        os_set_inheritable(fd, True)
        self._close_after_spawn(fd)
        return fd

    cdef _file_devnull(self):
        dn = os_open(os_devnull, os_O_RDWR)
        os_set_inheritable(dn, True)
        self._close_after_spawn(dn)
        return dn

    cdef _file_outpipe(self):
        r, w = os_pipe()
        os_set_inheritable(w, True)
        self._close_after_spawn(w)
        return r, w

    cdef _init_files(self, stdin, stdout, stderr):
        cdef uv.uv_stdio_container_t *iocnt

        UVProcess._init_files(self, stdin, stdout, stderr)

        self.stdin = self.stdout = self.stderr = None
        io = [None, None, None]

        self.options.stdio_count = 3
        self.options.stdio = self.iocnt

        if stdin is not None:
            if stdin == subprocess_PIPE:
                proto = WriteSubprocessPipeProto(self, 0)
                self.stdin = UVWritePipeTransport.new(self._loop, proto, None)

                iocnt = &self.iocnt[0]
                iocnt.flags = <uv.uv_stdio_flags>(uv.UV_CREATE_PIPE |
                                                  uv.UV_READABLE_PIPE)
                iocnt.data.stream = <uv.uv_stream_t*>self.stdin._handle
            elif stdin == subprocess_DEVNULL:
                io[0] = self._file_devnull()
            elif stdout == subprocess_STDOUT:
                raise ValueError(
                    'subprocess.STDOUT is supported only by stderr parameter')
            else:
                raise ValueError(
                    'invalid stdin argument value {!r}'.format(stdin))
        else:
            io[0] = self._file_redirect_stdio(sys.stdin.fileno())

        if stdout is not None:
            if stdout == subprocess_PIPE:
                # We can't use UV_CREATE_PIPE here, since 'stderr' might be
                # set to 'subprocess.STDOUT', and there is no way to
                # emulate that functionality with libuv high-level
                # streams API. Therefore, we create pipes for stdout and
                # stderr manually.

                r, w  = self._file_outpipe()
                io[1] = w

                proto = ReadSubprocessPipeProto(self, 1)
                self.stdout = UVReadPipeTransport.new(self._loop, proto, None)
                self.stdout.open(r)
            elif stdout == subprocess_DEVNULL:
                io[1] = self._file_devnull()
            elif stdout == subprocess_STDOUT:
                raise ValueError(
                    'subprocess.STDOUT is supported only by stderr parameter')
            else:
                raise ValueError(
                    'invalid stdout argument value {!r}'.format(stdin))
        else:
            io[1] = self._file_redirect_stdio(sys.stdout.fileno())

        if stderr is not None:
            if stderr == subprocess_PIPE:
                r, w  = self._file_outpipe()
                io[2] = w

                proto = ReadSubprocessPipeProto(self, 2)
                self.stderr = UVReadPipeTransport.new(self._loop, proto, None)
                self.stderr.open(r)
            elif stderr == subprocess_STDOUT:
                if io[1] is None:
                    # shouldn't ever happen
                    raise RuntimeError('cannot apply subprocess.STDOUT')

                newfd = os_dup(io[1])
                os_set_inheritable(newfd, True)
                self._close_after_spawn(newfd)
                io[2] = newfd
            elif stdout == subprocess_DEVNULL:
                io[2] = self._file_devnull()
            else:
                raise ValueError(
                    'invalid stderr argument value {!r}'.format(stdin))
        else:
            io[2] = self._file_redirect_stdio(sys.stderr.fileno())

        assert len(io) == 3
        for idx in range(3):
            if io[idx] is not None:
                iocnt = &self.iocnt[idx]
                iocnt.flags = uv.UV_INHERIT_FD
                iocnt.data.fd = io[idx]

    @staticmethod
    cdef UVProcessTransport new(Loop loop, protocol, args, env,
                                cwd, start_new_session,
                                stdin, stdout, stderr, pass_fds,
                                waiter):

        cdef UVProcessTransport handle
        handle = UVProcessTransport.__new__(UVProcessTransport)
        handle._protocol = protocol
        handle._init(loop, args, env, cwd, start_new_session,
                     __process_convert_fileno(stdin),
                     __process_convert_fileno(stdout),
                     __process_convert_fileno(stderr),
                     pass_fds)

        if handle.stdin is not None:
            handle.stdin._init_protocol(None)
        if handle.stdout is not None:
            handle.stdout._init_protocol(None)
        if handle.stderr is not None:
            handle.stderr._init_protocol(None)

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

    def get_extra_info(self, name, default=None):
        return default

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
