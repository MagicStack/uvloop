"""Test utilities. Don't use outside of the uvloop project."""


import asyncio
import gc
import inspect
import re
import socket
import ssl
import tempfile
import threading
import unittest
import uvloop


class MockPattern(str):
    def __eq__(self, other):
        return bool(re.search(str(self), other, re.S))


class BaseTestCase(unittest.TestCase):

    def new_loop(self):
        raise NotImplementedError

    def mock_pattern(self, str):
        return MockPattern(str)

    def setUp(self):
        self.loop = self.new_loop()
        asyncio.set_event_loop(self.loop)

    def tearDown(self):
        self.loop.close()

        if getattr(self.loop, '_debug_cc', False):
            gc.collect()
            gc.collect()
            gc.collect()

            self.assertEqual(self.loop._debug_cb_handles_count, 0)
            self.assertEqual(self.loop._debug_cb_timer_handles_count, 0)
            self.assertEqual(self.loop._debug_stream_write_ctx_cnt, 0)

            for h_name, h_cnt in self.loop._debug_handles_current.items():
                with self.subTest('Alive handle after test',
                                  handle_name=h_name):
                    self.assertEqual(h_cnt, 0)

            for h_name, h_cnt in self.loop._debug_handles_total.items():
                with self.subTest('Total/closed handles',
                                  handle_name=h_name):
                    self.assertEqual(
                        h_cnt, self.loop._debug_handles_closed[h_name])

        asyncio.set_event_loop(None)
        self.loop = None


class UVTestCase(BaseTestCase):

    def new_loop(self):
        return uvloop.new_event_loop()


class AIOTestCase(BaseTestCase):

    def new_loop(self):
        return asyncio.new_event_loop()


###############################################################################
## Socket Testing Utilities
###############################################################################


def unix_server(server_prog, *,
                addr=None,
                timeout=1,
                backlog=1,
                max_clients=1):

    if not inspect.isgeneratorfunction(server_prog):
        raise TypeError('server_prog: a generator function was expected')

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    if timeout is None:
        raise RuntimeError('timeout is required')
    if timeout <= 0:
        raise RuntimeError('only blocking sockets are supported')
    sock.settimeout(timeout)

    if addr is None:
        with tempfile.NamedTemporaryFile() as tmp:
            addr = tmp.name

    try:
        sock.bind(addr)
        sock.listen(backlog)
    except OSError as ex:
        sock.close()
        raise ex

    srv = Server(sock, server_prog, timeout, max_clients)
    return srv


def tcp_server(server_prog, *,
               family=socket.AF_INET,
               addr=('127.0.0.1', 0),
               timeout=1,
               backlog=1,
               max_clients=1):

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

    srv = Server(sock, server_prog, timeout, max_clients)
    return srv


class Server(threading.Thread):

    def __init__(self, sock, prog, timeout, max_clients):
        threading.Thread.__init__(self, None, None, 'test-server')
        self.daemon = True

        self._clients = 0
        self._finished_clients = 0
        self._max_clients = max_clients
        self._timeout = timeout
        self._sock = sock
        self._active = True

        self._prog = prog

    def run(self):
        with self._sock:
            while self._active:
                if self._clients >= self._max_clients:
                    return
                try:
                    conn, addr = self._sock.accept()
                except socket.timeout:
                    if not self._active:
                        return
                    else:
                        raise
                self._clients += 1
                conn.settimeout(self._timeout)
                try:
                    with conn:
                        self._handle_client(conn)
                except Exception:
                    self._active = False
                    raise

    def _handle_client(self, sock):
        prog = self._prog()

        last_val = None
        while self._active:
            try:
                command = prog.send(last_val)
            except StopIteration:
                self._finished_clients += 1
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
        self.join()

        if self._finished_clients != self._clients:
            raise AssertionError(
                'not all clients are finished: {!r}'.format(
                    self._clients - self._finished_clients))

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()


class Command:

    def _run(self, sock):
        raise NotImplementedError


class write(Command):

    def __init__(self, data:bytes):
        self._data = data

    def _run(self, sock):
        sock.sendall(self._data)
        return sock, None


class close(Command):
    def _run(self, sock):
        sock.close()
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
