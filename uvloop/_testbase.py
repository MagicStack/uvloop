"""Test utilities. Don't use outside of the uvloop project."""


import asyncio
import contextlib
import gc
import inspect
import logging
import os
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


def _cert_fullname(name):
    fullname = os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        'tests', 'certs', name)
    assert os.path.isfile(fullname)
    return fullname


@contextlib.contextmanager
def silence_long_exec_warning():

    class Filter(logging.Filter):
        def filter(self, record):
            return not (record.msg.startswith('Executing') and
                        record.msg.endswith('seconds'))

    logger = logging.getLogger('asyncio')
    filter = Filter()
    logger.addFilter(filter)
    try:
        yield
    finally:
        logger.removeFilter(filter)


def find_free_port(start_from=50000):
    for port in range(start_from, start_from + 500):
        sock = socket.socket()
        with sock:
            try:
                sock.bind(('', port))
            except socket.error:
                continue
            else:
                return port
    raise RuntimeError('could not find a free port')


class SSLTestCase:

    ONLYCERT = _cert_fullname('ssl_cert.pem')
    ONLYKEY = _cert_fullname('ssl_key.pem')

    def _create_server_ssl_context(self, certfile, keyfile=None):
        sslcontext = ssl.SSLContext(ssl.PROTOCOL_SSLv23)
        sslcontext.options |= ssl.OP_NO_SSLv2
        sslcontext.load_cert_chain(certfile, keyfile)
        return sslcontext

    def _create_client_ssl_context(self):
        sslcontext = ssl.create_default_context()
        sslcontext.check_hostname = False
        sslcontext.verify_mode = ssl.CERT_NONE
        return sslcontext

    @contextlib.contextmanager
    def _silence_eof_received_warning(self):
        # TODO This warning has to be fixed in asyncio.
        logger = logging.getLogger('asyncio')
        filter = logging.Filter('has no effect when using ssl')
        logger.addFilter(filter)
        try:
            yield
        finally:
            logger.removeFilter(filter)


class UVTestCase(BaseTestCase):

    def new_loop(self):
        return uvloop.new_event_loop()


class AIOTestCase(BaseTestCase):

    def new_loop(self):
        return asyncio.new_event_loop()


###############################################################################
# Socket Testing Utilities
###############################################################################


def tcp_server(server_prog, *,
               family=socket.AF_INET,
               addr=None,
               timeout=5,
               backlog=1,
               max_clients=10):

    if addr is None:
        if family == socket.AF_UNIX:
            with tempfile.NamedTemporaryFile() as tmp:
                addr = tmp.name
        else:
            addr = ('127.0.0.1', 0)

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


def tcp_client(client_prog,
               family=socket.AF_INET,
               timeout=10):

    if not inspect.isgeneratorfunction(client_prog):
        raise TypeError('client_prog: a generator function was expected')

    sock = socket.socket(family, socket.SOCK_STREAM)

    if timeout is None:
        raise RuntimeError('timeout is required')
    if timeout <= 0:
        raise RuntimeError('only blocking sockets are supported')
    sock.settimeout(timeout)

    srv = Client(sock, client_prog, timeout)
    return srv


class _Runner:
    def _iterate(self, prog, sock):
        last_val = None
        while self._active:
            try:
                command = prog.send(last_val)
            except StopIteration:
                return

            if not isinstance(command, _Command):
                raise TypeError(
                    'client_prog yielded invalid command {!r}'.format(command))

            command_res = command._run(sock)
            assert isinstance(command_res, tuple) and len(command_res) == 2

            last_val = command_res[1]
            sock = command_res[0]

    def stop(self):
        self._active = False
        self.join()

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()


class Client(_Runner, threading.Thread):

    def __init__(self, sock, prog, timeout):
        threading.Thread.__init__(self, None, None, 'test-client')
        self.daemon = True

        self._timeout = timeout
        self._sock = sock
        self._active = True
        self._prog = prog

    def run(self):
        prog = self._prog()
        sock = self._sock
        self._iterate(prog, sock)


class Server(_Runner, threading.Thread):

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
        self._iterate(prog, sock)

    @property
    def addr(self):
        return self._sock.getsockname()


class _Command:

    def _run(self, sock):
        raise NotImplementedError


class write(_Command):

    def __init__(self, data:bytes):
        self._data = data

    def _run(self, sock):
        sock.sendall(self._data)
        return sock, None


class connect(_Command):
    def __init__(self, addr):
        self._addr = addr

    def _run(self, sock):
        sock.connect(self._addr)
        return sock, None


class close(_Command):
    def _run(self, sock):
        sock.close()
        return sock, None


class read(_Command):

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


class starttls(_Command):

    def __init__(self, ssl_context, *,
                 server_side=False,
                 server_hostname=None,
                 do_handshake_on_connect=True):

        assert isinstance(ssl_context, ssl.SSLContext)
        self._ctx = ssl_context

        self._server_side = server_side
        self._server_hostname = server_hostname
        self._do_handshake_on_connect = do_handshake_on_connect

    def _run(self, sock):
        ssl_sock = self._ctx.wrap_socket(
            sock, server_side=self._server_side,
            server_hostname=self._server_hostname,
            do_handshake_on_connect=self._do_handshake_on_connect)

        if self._server_side:
            ssl_sock.do_handshake()

        return ssl_sock, None
