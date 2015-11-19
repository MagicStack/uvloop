import inspect
import socket
import ssl
import threading


def start_tcp_server(server_prog, *,
                     family=socket.AF_INET,
                     addr=('127.0.0.1', 0),
                     timeout=60,
                     backlog=1):

    if not inspect.isgeneratorfunction(server_prog):
        raise TypeError('server_prog: a generator function was expected')

    sock = socket.socket(family, socket.SOCK_STREAM)

    if timeout is None:
        raise RuntimeError('timeout is required')
    if timeout <= 0:
        raise RuntimeError('only blocking sockets are supported')
    sock.settimeout(timeout)

    try:
        sock.bind(addr)
        sock.listen(backlog)
    except OSError as ex:
        sock.close()
        raise ex

    srv = Server(sock, server_prog)
    srv.start()
    return srv


class Server(threading.Thread):
    def __init__(self, sock, prog):
        threading.Thread.__init__(self, None, None, 'test-server')
        self.daemon = True

        self._sock = sock
        self._active = True

        self._prog = prog

    def run(self):
        try:
            while self._active:
                conn, addr = self._sock.accept()
                try:
                    self._handle_client(conn)
                except Exception:
                    self._active = False
                    raise
                finally:
                    conn.close()
        finally:
            self._sock.close()

    def _handle_client(self, sock):
        prog = self._prog()

        last_val = None
        while self._active:
            try:
                command = prog.send(last_val)
            except StopIteration:
                return

            if not isinstance(command, Command):
                raise TypeError(
                    'server_prog yielded invalid command {!r}'.format(command))

            command_res = command._run(sock)
            assert isinstance(command_res, tuple) and len(command_res) == 2

            last_val = command_res[1]
            sock = command_res[0]


    @property
    def addr(self):
        return self._sock.getsockname()

    def stop(self):
        self._active = False


class Command:
    def _run(self, sock):
        raise NotImplementedError


class write(Command):
    def __init__(self, data:bytes):
        self._data = data

    def _run(self, sock):
        sock.sendall(self._data)
        return sock, None


class read(Command):
    def __init__(self, nbytes):
        self._nbytes = nbytes
        self._nbytes_recv = 0
        self._data = []

    def _run(self, sock):
        while self._nbytes_recv != self._nbytes:
            try:
                data = sock.recv(self._nbytes)
            except InterruptedError:
                # for Python < 3.5
                continue

            if data == b'':
                raise ConnectionAbortedError

            self._nbytes_recv += len(data)
            self._data.append(data)

        data = b''.join(self._data)
        return sock, data


class starttls(Command):
    def __init__(self, ssl_context, *,
                 server_side=False,
                 server_hostname=None):

        assert isinstance(ssl_context, ssl.SSLContext)
        self._ctx = ssl_context

        self._server_side = server_side
        self._server_hostname = server_hostname

    def _run(self, sock):
        ssl_sock = self._ctx.wrap_socket(
            sock, server_side=self._server_side,
            server_hostname=self._server_hostname)

        ssl_sock.do_handshake()

        return ssl_sock, None
