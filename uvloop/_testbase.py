"""Test utilities. Don't use outside of the uvloop project."""


import asyncio
import asyncio.events
import collections
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


class TestCaseDict(collections.UserDict):

    def __init__(self, name):
        super().__init__()
        self.name = name

    def __setitem__(self, key, value):
        if key in self.data:
            raise RuntimeError('duplicate test {}.{}'.format(
                self.name, key))
        super().__setitem__(key, value)


class BaseTestCaseMeta(type):

    @classmethod
    def __prepare__(mcls, name, bases):
        return TestCaseDict(name)

    def __new__(mcls, name, bases, dct):
        for test_name in dct:
            if not test_name.startswith('test_'):
                continue
            for base in bases:
                if hasattr(base, test_name):
                    raise RuntimeError(
                        'duplicate test {}.{} (also defined in {} '
                        'parent class)'.format(
                            name, test_name, base.__name__))

        return super().__new__(mcls, name, bases, dict(dct))


class BaseTestCase(unittest.TestCase, metaclass=BaseTestCaseMeta):

    def new_loop(self):
        raise NotImplementedError

    def mock_pattern(self, str):
        return MockPattern(str)

    def is_asyncio_loop(self):
        return type(self.loop).__module__.startswith('asyncio.')

    def setUp(self):
        self.loop = self.new_loop()
        asyncio.set_event_loop(None)
        self._check_unclosed_resources_in_debug = True

        if hasattr(asyncio, '_get_running_loop'):
            # Disable `_get_running_loop`.
            self._get_running_loop = asyncio.events._get_running_loop
            asyncio.events._get_running_loop = lambda: None

    def tearDown(self):
        self.loop.close()

        if hasattr(asyncio, '_get_running_loop'):
            asyncio.events._get_running_loop = self._get_running_loop

        if not self._check_unclosed_resources_in_debug:
            return

        # GC to show any resource warnings as the test completes
        gc.collect()
        gc.collect()
        gc.collect()

        if getattr(self.loop, '_debug_cc', False):
            gc.collect()
            gc.collect()
            gc.collect()

            self.assertEqual(
                self.loop._debug_uv_handles_total,
                self.loop._debug_uv_handles_freed,
                'not all uv_handle_t handles were freed')

            self.assertEqual(
                self.loop._debug_cb_handles_count, 0,
                'not all callbacks (call_soon) are GCed')

            self.assertEqual(
                self.loop._debug_cb_timer_handles_count, 0,
                'not all timer callbacks (call_later) are GCed')

            self.assertEqual(
                self.loop._debug_stream_write_ctx_cnt, 0,
                'not all stream write contexts are GCed')

            for h_name, h_cnt in self.loop._debug_handles_current.items():
                with self.subTest('Alive handle after test',
                                  handle_name=h_name):
                    self.assertEqual(
                        h_cnt, 0,
                        'alive {} after test'.format(h_name))

            for h_name, h_cnt in self.loop._debug_handles_total.items():
                with self.subTest('Total/closed handles',
                                  handle_name=h_name):
                    self.assertEqual(
                        h_cnt, self.loop._debug_handles_closed[h_name],
                        'total != closed for {}'.format(h_name))

        asyncio.set_event_loop(None)
        self.loop = None

    def skip_unclosed_handles_check(self):
        self._check_unclosed_resources_in_debug = False


def _cert_fullname(test_file_name, cert_file_name):
    fullname = os.path.abspath(os.path.join(
        os.path.dirname(test_file_name), 'certs', cert_file_name))
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

    def setUp(self):
        super().setUp()

        watcher = asyncio.SafeChildWatcher()
        watcher.attach_loop(self.loop)
        asyncio.set_child_watcher(watcher)

    def tearDown(self):
        asyncio.set_child_watcher(None)
        super().tearDown()

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
