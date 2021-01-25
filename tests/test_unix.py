import asyncio
import os
import pathlib
import socket
import tempfile
import time
import unittest
import sys

from uvloop import _testbase as tb


class _TestUnix:
    def test_create_unix_server_1(self):
        CNT = 0           # number of clients that were successful
        TOTAL_CNT = 100   # total number of clients that test will create
        TIMEOUT = 5.0     # timeout for this test

        async def handle_client(reader, writer):
            nonlocal CNT

            data = await reader.readexactly(4)
            self.assertEqual(data, b'AAAA')
            writer.write(b'OK')

            data = await reader.readexactly(4)
            self.assertEqual(data, b'BBBB')
            writer.write(b'SPAM')

            await writer.drain()
            writer.close()
            await self.wait_closed(writer)

            CNT += 1

        async def test_client(addr):
            sock = socket.socket(socket.AF_UNIX)
            with sock:
                sock.setblocking(False)
                await self.loop.sock_connect(sock, addr)

                await self.loop.sock_sendall(sock, b'AAAA')

                buf = b''
                while len(buf) != 2:
                    buf += await self.loop.sock_recv(sock, 1)
                self.assertEqual(buf, b'OK')

                await self.loop.sock_sendall(sock, b'BBBB')

                buf = b''
                while len(buf) != 4:
                    buf += await self.loop.sock_recv(sock, 1)
                self.assertEqual(buf, b'SPAM')

        async def start_server():
            nonlocal CNT
            CNT = 0

            with tempfile.TemporaryDirectory() as td:
                sock_name = os.path.join(td, 'sock')
                srv = await asyncio.start_unix_server(
                    handle_client,
                    sock_name)

                try:
                    srv_socks = srv.sockets
                    self.assertTrue(srv_socks)
                    self.assertTrue(srv.is_serving())

                    tasks = []
                    for _ in range(TOTAL_CNT):
                        tasks.append(test_client(sock_name))

                    await asyncio.wait_for(asyncio.gather(*tasks), TIMEOUT)

                finally:
                    self.loop.call_soon(srv.close)
                    await srv.wait_closed()

                    # Check that the server cleaned-up proxy-sockets
                    for srv_sock in srv_socks:
                        self.assertEqual(srv_sock.fileno(), -1)

                    self.assertFalse(srv.is_serving())

                # asyncio doesn't cleanup the sock file
                self.assertTrue(os.path.exists(sock_name))

        async def start_server_sock(start_server):
            nonlocal CNT
            CNT = 0

            with tempfile.TemporaryDirectory() as td:
                sock_name = os.path.join(td, 'sock')
                sock = socket.socket(socket.AF_UNIX)
                sock.bind(sock_name)

                srv = await start_server(sock)

                try:
                    srv_socks = srv.sockets
                    self.assertTrue(srv_socks)
                    self.assertTrue(srv.is_serving())

                    tasks = []
                    for _ in range(TOTAL_CNT):
                        tasks.append(test_client(sock_name))

                    await asyncio.wait_for(asyncio.gather(*tasks), TIMEOUT)

                finally:
                    self.loop.call_soon(srv.close)
                    await srv.wait_closed()

                    # Check that the server cleaned-up proxy-sockets
                    for srv_sock in srv_socks:
                        self.assertEqual(srv_sock.fileno(), -1)

                    self.assertFalse(srv.is_serving())

                # asyncio doesn't cleanup the sock file
                self.assertTrue(os.path.exists(sock_name))

        with self.subTest(func='start_unix_server(host, port)'):
            self.loop.run_until_complete(start_server())
            self.assertEqual(CNT, TOTAL_CNT)

        with self.subTest(func='start_unix_server(sock)'):
            self.loop.run_until_complete(start_server_sock(
                lambda sock: asyncio.start_unix_server(
                    handle_client,
                    None,
                    sock=sock)))
            self.assertEqual(CNT, TOTAL_CNT)

        with self.subTest(func='start_server(sock)'):
            self.loop.run_until_complete(start_server_sock(
                lambda sock: asyncio.start_server(
                    handle_client,
                    None, None,
                    sock=sock)))
            self.assertEqual(CNT, TOTAL_CNT)

    def test_create_unix_server_2(self):
        with tempfile.TemporaryDirectory() as td:
            sock_name = os.path.join(td, 'sock')
            with open(sock_name, 'wt') as f:
                f.write('x')

            with self.assertRaisesRegex(
                    OSError, "Address '{}' is already in use".format(
                        sock_name)):

                self.loop.run_until_complete(
                    self.loop.create_unix_server(object, sock_name))

    def test_create_unix_server_3(self):
        with self.assertRaisesRegex(
                ValueError, 'ssl_handshake_timeout is only meaningful'):
            self.loop.run_until_complete(
                self.loop.create_unix_server(
                    lambda: None, path='/tmp/a', ssl_handshake_timeout=10))

    def test_create_unix_server_existing_path_sock(self):
        with self.unix_sock_name() as path:
            sock = socket.socket(socket.AF_UNIX)
            with sock:
                sock.bind(path)
                sock.listen(1)

            # Check that no error is raised -- `path` is removed.
            coro = self.loop.create_unix_server(lambda: None, path)
            srv = self.loop.run_until_complete(coro)
            srv.close()
            self.loop.run_until_complete(srv.wait_closed())

    def test_create_unix_connection_open_unix_con_addr(self):
        async def client(addr):
            reader, writer = await asyncio.open_unix_connection(addr)

            writer.write(b'AAAA')
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(b'BBBB')
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            writer.close()
            await self.wait_closed(writer)

        self._test_create_unix_connection_1(client)

    def test_create_unix_connection_open_unix_con_sock(self):
        async def client(addr):
            sock = socket.socket(socket.AF_UNIX)
            sock.connect(addr)
            reader, writer = await asyncio.open_unix_connection(sock=sock)

            writer.write(b'AAAA')
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(b'BBBB')
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            writer.close()
            await self.wait_closed(writer)

        self._test_create_unix_connection_1(client)

    def test_create_unix_connection_open_con_sock(self):
        async def client(addr):
            sock = socket.socket(socket.AF_UNIX)
            sock.connect(addr)
            reader, writer = await asyncio.open_connection(sock=sock)

            writer.write(b'AAAA')
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(b'BBBB')
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            writer.close()
            await self.wait_closed(writer)

        self._test_create_unix_connection_1(client)

    def _test_create_unix_connection_1(self, client):
        CNT = 0
        TOTAL_CNT = 100

        def server(sock):
            data = sock.recv_all(4)
            self.assertEqual(data, b'AAAA')
            sock.send(b'OK')

            data = sock.recv_all(4)
            self.assertEqual(data, b'BBBB')
            sock.send(b'SPAM')

        async def client_wrapper(addr):
            await client(addr)
            nonlocal CNT
            CNT += 1

        def run(coro):
            nonlocal CNT
            CNT = 0

            with self.unix_server(server,
                                  max_clients=TOTAL_CNT,
                                  backlog=TOTAL_CNT) as srv:
                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(coro(srv.addr))

                self.loop.run_until_complete(asyncio.gather(*tasks))

                # Give time for all transports to close.
                self.loop.run_until_complete(asyncio.sleep(0.1))

            self.assertEqual(CNT, TOTAL_CNT)

        run(client_wrapper)

    def test_create_unix_connection_2(self):
        with tempfile.NamedTemporaryFile() as tmp:
            path = tmp.name

        async def client():
            reader, writer = await asyncio.open_unix_connection(path)
            writer.close()
            await self.wait_closed(writer)

        async def runner():
            with self.assertRaises(FileNotFoundError):
                await client()

        self.loop.run_until_complete(runner())

    def test_create_unix_connection_3(self):
        CNT = 0
        TOTAL_CNT = 100

        def server(sock):
            data = sock.recv_all(4)
            self.assertEqual(data, b'AAAA')
            sock.close()

        async def client(addr):
            reader, writer = await asyncio.open_unix_connection(addr)

            sock = writer._transport.get_extra_info('socket')
            self.assertEqual(sock.family, socket.AF_UNIX)

            writer.write(b'AAAA')

            with self.assertRaises(asyncio.IncompleteReadError):
                await reader.readexactly(10)

            writer.close()
            await self.wait_closed(writer)

            nonlocal CNT
            CNT += 1

        def run(coro):
            nonlocal CNT
            CNT = 0

            with self.unix_server(server,
                                  max_clients=TOTAL_CNT,
                                  backlog=TOTAL_CNT) as srv:
                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(coro(srv.addr))

                self.loop.run_until_complete(asyncio.gather(*tasks))

            self.assertEqual(CNT, TOTAL_CNT)

        run(client)

    def test_create_unix_connection_4(self):
        sock = socket.socket(socket.AF_UNIX)
        sock.close()

        async def client():
            reader, writer = await asyncio.open_unix_connection(sock=sock)
            writer.close()
            await self.wait_closed(writer)

        async def runner():
            with self.assertRaisesRegex(OSError, 'Bad file'):
                await client()

        self.loop.run_until_complete(runner())

    def test_create_unix_connection_5(self):
        s1, s2 = socket.socketpair(socket.AF_UNIX)

        excs = []

        class Proto(asyncio.Protocol):
            def connection_lost(self, exc):
                excs.append(exc)

        proto = Proto()

        async def client():
            t, _ = await self.loop.create_unix_connection(
                lambda: proto,
                None,
                sock=s2)

            t.write(b'AAAAA')
            s1.close()
            t.write(b'AAAAA')
            await asyncio.sleep(0.1)

        self.loop.run_until_complete(client())

        self.assertEqual(len(excs), 1)
        self.assertIn(excs[0].__class__,
                      (BrokenPipeError, ConnectionResetError))

    def test_create_unix_connection_6(self):
        with self.assertRaisesRegex(
                ValueError, 'ssl_handshake_timeout is only meaningful'):
            self.loop.run_until_complete(
                self.loop.create_unix_connection(
                    lambda: None, path='/tmp/a', ssl_handshake_timeout=10))


class Test_UV_Unix(_TestUnix, tb.UVTestCase):

    @unittest.skipUnless(hasattr(os, 'fspath'), 'no os.fspath()')
    def test_create_unix_connection_pathlib(self):
        async def run(addr):
            t, _ = await self.loop.create_unix_connection(
                asyncio.Protocol, addr)
            t.close()

        with self.unix_server(lambda sock: time.sleep(0.01)) as srv:
            addr = pathlib.Path(srv.addr)
            self.loop.run_until_complete(run(addr))

    @unittest.skipUnless(hasattr(os, 'fspath'), 'no os.fspath()')
    def test_create_unix_server_pathlib(self):
        with self.unix_sock_name() as srv_path:
            srv_path = pathlib.Path(srv_path)
            srv = self.loop.run_until_complete(
                self.loop.create_unix_server(asyncio.Protocol, srv_path))
            srv.close()
            self.loop.run_until_complete(srv.wait_closed())

    def test_transport_fromsock_get_extra_info(self):
        # This tests is only for uvloop.  asyncio should pass it
        # too in Python 3.6.

        async def test(sock):
            t, _ = await self.loop.create_unix_connection(
                asyncio.Protocol,
                sock=sock)

            sock = t.get_extra_info('socket')
            self.assertIs(t.get_extra_info('socket'), sock)

            with self.assertRaisesRegex(RuntimeError, 'is used by transport'):
                self.loop.add_writer(sock.fileno(), lambda: None)
            with self.assertRaisesRegex(RuntimeError, 'is used by transport'):
                self.loop.remove_writer(sock.fileno())

            t.close()

        s1, s2 = socket.socketpair(socket.AF_UNIX)
        with s1, s2:
            self.loop.run_until_complete(test(s1))

    def test_create_unix_server_path_dgram(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        with sock:
            coro = self.loop.create_unix_server(lambda: None,
                                                sock=sock)
            with self.assertRaisesRegex(ValueError,
                                        'A UNIX Domain Stream.*was expected'):
                self.loop.run_until_complete(coro)

    @unittest.skipUnless(hasattr(socket, 'SOCK_NONBLOCK'),
                         'no socket.SOCK_NONBLOCK (linux only)')
    def test_create_unix_server_path_stream_bittype(self):
        sock = socket.socket(
            socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_NONBLOCK)
        with tempfile.NamedTemporaryFile() as file:
            fn = file.name
        try:
            with sock:
                sock.bind(fn)
                coro = self.loop.create_unix_server(lambda: None, path=None,
                                                    sock=sock)
                srv = self.loop.run_until_complete(coro)
                srv.close()
                self.loop.run_until_complete(srv.wait_closed())
        finally:
            os.unlink(fn)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'requires epoll')
    def test_epollhup(self):
        SIZE = 50
        eof = False
        done = False
        recvd = b''

        class Proto(asyncio.BaseProtocol):
            def connection_made(self, tr):
                tr.write(b'hello')
                self.data = bytearray(SIZE)
                self.buf = memoryview(self.data)

            def get_buffer(self, sizehint):
                return self.buf

            def buffer_updated(self, nbytes):
                nonlocal recvd
                recvd += self.buf[:nbytes]

            def eof_received(self):
                nonlocal eof
                eof = True

            def connection_lost(self, exc):
                nonlocal done
                done = exc

        async def test():
            with tempfile.TemporaryDirectory() as td:
                sock_name = os.path.join(td, 'sock')
                srv = await self.loop.create_unix_server(Proto, sock_name)

                s = socket.socket(socket.AF_UNIX)
                with s:
                    s.setblocking(False)
                    await self.loop.sock_connect(s, sock_name)
                    d = await self.loop.sock_recv(s, 100)
                    self.assertEqual(d, b'hello')

                    # IMPORTANT: overflow recv buffer and close immediately
                    await self.loop.sock_sendall(s, b'a' * (SIZE + 1))

                srv.close()
                await srv.wait_closed()

        self.loop.run_until_complete(test())
        self.assertTrue(eof)
        self.assertIsNone(done)
        self.assertEqual(recvd, b'a' * (SIZE + 1))


class Test_AIO_Unix(_TestUnix, tb.AIOTestCase):
    pass


class _TestSSL(tb.SSLTestCase):

    ONLYCERT = tb._cert_fullname(__file__, 'ssl_cert.pem')
    ONLYKEY = tb._cert_fullname(__file__, 'ssl_key.pem')

    def test_create_unix_server_ssl_1(self):
        CNT = 0           # number of clients that were successful
        TOTAL_CNT = 25    # total number of clients that test will create
        TIMEOUT = 10.0    # timeout for this test

        A_DATA = b'A' * 1024 * 1024
        B_DATA = b'B' * 1024 * 1024

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()

        clients = []

        async def handle_client(reader, writer):
            nonlocal CNT

            data = await reader.readexactly(len(A_DATA))
            self.assertEqual(data, A_DATA)
            writer.write(b'OK')

            data = await reader.readexactly(len(B_DATA))
            self.assertEqual(data, B_DATA)
            writer.writelines([b'SP', bytearray(b'A'), memoryview(b'M')])

            await writer.drain()
            writer.close()

            CNT += 1

        async def test_client(addr):
            fut = asyncio.Future(loop=self.loop)

            def prog(sock):
                try:
                    sock.starttls(client_sslctx)

                    sock.connect(addr)
                    sock.send(A_DATA)

                    data = sock.recv_all(2)
                    self.assertEqual(data, b'OK')

                    sock.send(B_DATA)
                    data = sock.recv_all(4)
                    self.assertEqual(data, b'SPAM')

                    sock.close()

                except Exception as ex:
                    self.loop.call_soon_threadsafe(
                        lambda ex=ex:
                            (fut.cancelled() or fut.set_exception(ex)))
                else:
                    self.loop.call_soon_threadsafe(
                        lambda: (fut.cancelled() or fut.set_result(None)))

            client = self.unix_client(prog)
            client.start()
            clients.append(client)

            await fut

        async def start_server():
            extras = dict(ssl_handshake_timeout=10.0)

            with tempfile.TemporaryDirectory() as td:
                sock_name = os.path.join(td, 'sock')

                srv = await asyncio.start_unix_server(
                    handle_client,
                    sock_name,
                    ssl=sslctx,
                    **extras)

                try:
                    tasks = []
                    for _ in range(TOTAL_CNT):
                        tasks.append(test_client(sock_name))

                    await asyncio.wait_for(asyncio.gather(*tasks), TIMEOUT)

                finally:
                    self.loop.call_soon(srv.close)
                    await srv.wait_closed()

        try:
            with self._silence_eof_received_warning():
                self.loop.run_until_complete(start_server())
        except asyncio.TimeoutError:
            if os.environ.get('TRAVIS_OS_NAME') == 'osx':
                # XXX: figure out why this fails on macOS on Travis
                raise unittest.SkipTest('unexplained error on Travis macOS')
            else:
                raise

        self.assertEqual(CNT, TOTAL_CNT)

        for client in clients:
            client.stop()

    def test_create_unix_connection_ssl_1(self):
        CNT = 0
        TOTAL_CNT = 25

        A_DATA = b'A' * 1024 * 1024
        B_DATA = b'B' * 1024 * 1024

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()

        def server(sock):
            sock.starttls(sslctx, server_side=True)

            data = sock.recv_all(len(A_DATA))
            self.assertEqual(data, A_DATA)
            sock.send(b'OK')

            data = sock.recv_all(len(B_DATA))
            self.assertEqual(data, B_DATA)
            sock.send(b'SPAM')

            sock.close()

        async def client(addr):
            extras = dict(ssl_handshake_timeout=10.0)

            reader, writer = await asyncio.open_unix_connection(
                addr,
                ssl=client_sslctx,
                server_hostname='',
                **extras)

            writer.write(A_DATA)
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(B_DATA)
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            nonlocal CNT
            CNT += 1

            writer.close()
            await self.wait_closed(writer)

        def run(coro):
            nonlocal CNT
            CNT = 0

            with self.unix_server(server,
                                  max_clients=TOTAL_CNT,
                                  backlog=TOTAL_CNT) as srv:
                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(coro(srv.addr))

                self.loop.run_until_complete(asyncio.gather(*tasks))

            self.assertEqual(CNT, TOTAL_CNT)

        with self._silence_eof_received_warning():
            run(client)


class Test_UV_UnixSSL(_TestSSL, tb.UVTestCase):
    pass


class Test_AIO_UnixSSL(_TestSSL, tb.AIOTestCase):
    pass
