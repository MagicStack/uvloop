import asyncio
import socket
import unittest
import uvloop
import sys

from uvloop import _testbase as tb


class _TestTCP:
    def test_create_server_1(self):
        CNT = 0           # number of clients that were successful
        TOTAL_CNT = 25    # total number of clients that test will create
        TIMEOUT = 5.0     # timeout for this test

        A_DATA = b'A' * 1024 * 1024
        B_DATA = b'B' * 1024 * 1024

        async def handle_client(reader, writer):
            nonlocal CNT

            data = await reader.readexactly(len(A_DATA))
            self.assertEqual(data, A_DATA)
            writer.write(b'OK')

            data = await reader.readexactly(len(B_DATA))
            self.assertEqual(data, B_DATA)
            writer.writelines([b'S', b'P'])
            writer.write(bytearray(b'A'))
            writer.write(memoryview(b'M'))

            await writer.drain()
            writer.close()

            CNT += 1

        async def test_client(addr):
            sock = socket.socket()
            with sock:
                sock.setblocking(False)
                await self.loop.sock_connect(sock, addr)

                await self.loop.sock_sendall(sock, A_DATA)

                buf = b''
                while len(buf) != 2:
                    buf += await self.loop.sock_recv(sock, 1)
                self.assertEqual(buf, b'OK')

                await self.loop.sock_sendall(sock, B_DATA)

                buf = b''
                while len(buf) != 4:
                    buf += await self.loop.sock_recv(sock, 1)
                self.assertEqual(buf, b'SPAM')

        async def start_server():
            nonlocal CNT
            CNT = 0

            addrs = ('127.0.0.1', 'localhost')
            if not isinstance(self.loop, uvloop.Loop):
                # Hack to let tests run on Python 3.5.0
                # (asyncio doesn't support multiple hosts in 3.5.0)
                addrs = '127.0.0.1'

            srv = await asyncio.start_server(
                handle_client,
                addrs, 0,
                family=socket.AF_INET,
                loop=self.loop)

            srv_socks = srv.sockets
            self.assertTrue(srv_socks)

            addr = srv_socks[0].getsockname()

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(test_client(addr))

            await asyncio.wait_for(
                asyncio.gather(*tasks, loop=self.loop),
                TIMEOUT, loop=self.loop)

            self.loop.call_soon(srv.close)
            await srv.wait_closed()

            # Check that the server cleaned-up proxy-sockets
            for srv_sock in srv_socks:
                self.assertEqual(srv_sock.fileno(), -1)

        async def start_server_sock():
            nonlocal CNT
            CNT = 0

            sock = socket.socket()
            sock.bind(('127.0.0.1', 0))
            addr = sock.getsockname()

            srv = await asyncio.start_server(
                handle_client,
                None, None,
                family=socket.AF_INET,
                loop=self.loop,
                sock=sock)

            srv_socks = srv.sockets
            self.assertTrue(srv_socks)

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(test_client(addr))

            await asyncio.wait_for(
                asyncio.gather(*tasks, loop=self.loop),
                TIMEOUT, loop=self.loop)

            srv.close()
            await srv.wait_closed()

            # Check that the server cleaned-up proxy-sockets
            for srv_sock in srv_socks:
                self.assertEqual(srv_sock.fileno(), -1)

        self.loop.run_until_complete(start_server())
        self.assertEqual(CNT, TOTAL_CNT)

        self.loop.run_until_complete(start_server_sock())
        self.assertEqual(CNT, TOTAL_CNT)

    def test_create_server_2(self):
        with self.assertRaisesRegex(ValueError, 'nor sock were specified'):
            self.loop.run_until_complete(self.loop.create_server(object))

    def test_create_server_3(self):
        ''' check ephemeral port can be used '''

        async def start_server_ephemeral_ports():

            for port_sentinel in [0, None]:
                srv = await self.loop.create_server(
                    asyncio.Protocol,
                    '127.0.0.1', port_sentinel,
                    family=socket.AF_INET)

                srv_socks = srv.sockets
                self.assertTrue(srv_socks)

                host, port = srv_socks[0].getsockname()
                self.assertNotEqual(0, port)

                self.loop.call_soon(srv.close)
                await srv.wait_closed()

                # Check that the server cleaned-up proxy-sockets
                for srv_sock in srv_socks:
                    self.assertEqual(srv_sock.fileno(), -1)

        self.loop.run_until_complete(start_server_ephemeral_ports())

    def test_create_server_4(self):
        sock = socket.socket()
        sock.bind(('127.0.0.1', 0))

        with sock:
            addr = sock.getsockname()

            with self.assertRaisesRegex(OSError,
                                        "error while attempting.*\('127.*: "
                                        "address already in use"):

                self.loop.run_until_complete(
                    self.loop.create_server(object, *addr))

    def test_create_server_5(self):
        # Test that create_server sets the TCP_IPV6ONLY flag,
        # so it can bind to ipv4 and ipv6 addresses
        # simultaneously.

        port = tb.find_free_port()

        async def runner():
            srv = await self.loop.create_server(
                asyncio.Protocol,
                None, port)

            srv.close()
            await srv.wait_closed()

        self.loop.run_until_complete(runner())

    def test_create_server_6(self):
        if not hasattr(socket, 'SO_REUSEPORT'):
            raise unittest.SkipTest(
                'The system does not support SO_REUSEPORT')

        if sys.version_info[:3] < (3, 5, 1):
            raise unittest.SkipTest(
                'asyncio in CPython 3.5.0 does not have the '
                'reuse_port argument')

        port = tb.find_free_port()

        async def runner():
            srv1 = await self.loop.create_server(
                asyncio.Protocol,
                None, port,
                reuse_port=True)

            srv2 = await self.loop.create_server(
                asyncio.Protocol,
                None, port,
                reuse_port=True)

            srv1.close()
            srv2.close()

            await srv1.wait_closed()
            await srv2.wait_closed()

        self.loop.run_until_complete(runner())

    def test_create_connection_1(self):
        CNT = 0
        TOTAL_CNT = 100

        def server():
            data = yield tb.read(4)
            self.assertEqual(data, b'AAAA')
            yield tb.write(b'OK')

            data = yield tb.read(4)
            self.assertEqual(data, b'BBBB')
            yield tb.write(b'SPAM')

        async def client(addr):
            reader, writer = await asyncio.open_connection(
                *addr,
                loop=self.loop)

            writer.write(b'AAAA')
            self.assertEqual(await reader.readexactly(2), b'OK')

            re = r'(a bytes-like object)|(must be byte-ish)'
            with self.assertRaisesRegex(TypeError, re):
                writer.write('AAAA')

            writer.write(b'BBBB')
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            nonlocal CNT
            CNT += 1

            writer.close()

        async def client_2(addr):
            sock = socket.socket()
            sock.connect(addr)
            reader, writer = await asyncio.open_connection(
                sock=sock,
                loop=self.loop)

            writer.write(b'AAAA')
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(b'BBBB')
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            nonlocal CNT
            CNT += 1

            writer.close()

        def run(coro):
            nonlocal CNT
            CNT = 0

            srv = tb.tcp_server(server,
                                max_clients=TOTAL_CNT,
                                backlog=TOTAL_CNT)
            srv.start()

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(coro(srv.addr))

            self.loop.run_until_complete(
                asyncio.gather(*tasks, loop=self.loop))
            srv.join()
            self.assertEqual(CNT, TOTAL_CNT)

        run(client)
        run(client_2)

    def test_create_connection_2(self):
        sock = socket.socket()
        with sock:
            sock.bind(('127.0.0.1', 0))
            addr = sock.getsockname()

        async def client():
            reader, writer = await asyncio.open_connection(
                *addr,
                loop=self.loop)

        async def runner():
            with self.assertRaises(ConnectionRefusedError):
                await client()

        self.loop.run_until_complete(runner())

    def test_create_connection_3(self):
        CNT = 0
        TOTAL_CNT = 100

        def server():
            data = yield tb.read(4)
            self.assertEqual(data, b'AAAA')
            yield tb.close()

        async def client(addr):
            reader, writer = await asyncio.open_connection(
                *addr,
                loop=self.loop)

            writer.write(b'AAAA')

            with self.assertRaises(asyncio.IncompleteReadError):
                await reader.readexactly(10)

            writer.close()

            nonlocal CNT
            CNT += 1

        def run(coro):
            nonlocal CNT
            CNT = 0

            srv = tb.tcp_server(server,
                                max_clients=TOTAL_CNT,
                                backlog=TOTAL_CNT)
            srv.start()

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(coro(srv.addr))

            self.loop.run_until_complete(
                asyncio.gather(*tasks, loop=self.loop))
            srv.join()
            self.assertEqual(CNT, TOTAL_CNT)

        run(client)

    def test_create_connection_4(self):
        sock = socket.socket()
        sock.close()

        async def client():
            reader, writer = await asyncio.open_connection(
                sock=sock,
                loop=self.loop)

        async def runner():
            with self.assertRaisesRegex(OSError, 'Bad file'):
                await client()

        self.loop.run_until_complete(runner())

    def test_transport_shutdown(self):
        CNT = 0           # number of clients that were successful
        TOTAL_CNT = 100   # total number of clients that test will create
        TIMEOUT = 5.0     # timeout for this test

        async def handle_client(reader, writer):
            nonlocal CNT

            data = await reader.readexactly(4)
            self.assertEqual(data, b'AAAA')

            writer.write(b'OK')
            writer.write_eof()
            writer.write_eof()

            await writer.drain()
            writer.close()

            CNT += 1

        async def test_client(addr):
            reader, writer = await asyncio.open_connection(
                *addr,
                loop=self.loop)

            writer.write(b'AAAA')
            data = await reader.readexactly(2)
            self.assertEqual(data, b'OK')

            writer.close()

        async def start_server():
            nonlocal CNT
            CNT = 0

            srv = await asyncio.start_server(
                handle_client,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                loop=self.loop)

            srv_socks = srv.sockets
            self.assertTrue(srv_socks)

            addr = srv_socks[0].getsockname()

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(test_client(addr))

            await asyncio.wait_for(
                asyncio.gather(*tasks, loop=self.loop),
                TIMEOUT, loop=self.loop)

            srv.close()
            await srv.wait_closed()

        self.loop.run_until_complete(start_server())
        self.assertEqual(CNT, TOTAL_CNT)

    def test_transport_get_extra_info(self):
        fut = asyncio.Future(loop=self.loop)

        async def handle_client(reader, writer):
            with self.assertRaises(asyncio.IncompleteReadError):
                data = await reader.readexactly(4)
            writer.close()

            # Previously, when we used socket.fromfd to create a socket
            # for UVTransports (to make get_extra_info() work), a duplicate
            # of the socket was created, preventing UVTransport from being
            # properly closed.
            # This test ensures that server handle will receive an EOF
            # and finish the request.
            fut.set_result(None)

        async def test_client(addr):
            t, p = await self.loop.create_connection(
                lambda: asyncio.Protocol(), *addr)

            self.assertFalse(t._paused)
            t.pause_reading()
            self.assertTrue(t._paused)
            t.resume_reading()
            self.assertFalse(t._paused)

            sock = t.get_extra_info('socket')
            sockname = sock.getsockname()
            peername = sock.getpeername()

            self.assertTrue(isinstance(sock, socket.socket))
            self.assertEqual(t.get_extra_info('sockname'),
                             sockname)
            self.assertEqual(t.get_extra_info('peername'),
                             peername)

            t.write(b'OK')  # We want server to fail.

            self.assertFalse(t._closing)
            t.abort()
            self.assertTrue(t._closing)

            await fut

            # Test that peername and sockname are available after
            # the transport is closed.
            self.assertEqual(t.get_extra_info('peername'),
                             peername)
            self.assertEqual(t.get_extra_info('sockname'),
                             sockname)

        async def start_server():
            srv = await asyncio.start_server(
                handle_client,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                loop=self.loop)

            addr = srv.sockets[0].getsockname()
            await test_client(addr)

            srv.close()
            await srv.wait_closed()

        self.loop.run_until_complete(start_server())


class Test_UV_TCP(_TestTCP, tb.UVTestCase):

    def test_many_small_writes(self):
        N = 10000
        TOTAL = 0

        fut = self.loop.create_future()

        async def server(reader, writer):
            nonlocal TOTAL
            while True:
                d = await reader.read(10000)
                if not d:
                    break
                TOTAL += len(d)
            fut.set_result(True)
            writer.close()

        async def run():
            srv = await asyncio.start_server(
                server,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                loop=self.loop)

            addr = srv.sockets[0].getsockname()
            r, w = await asyncio.open_connection(*addr, loop=self.loop)

            DATA = b'x' * 102400

            # Test _StreamWriteContext with short sequences of writes
            w.write(DATA)
            await w.drain()
            for _ in range(3):
                w.write(DATA)
            await w.drain()
            for _ in range(10):
                w.write(DATA)
            await w.drain()

            for _ in range(N):
                w.write(DATA)

                try:
                    w.write('a')
                except TypeError:
                    pass

            await w.drain()
            for _ in range(N):
                w.write(DATA)
                await w.drain()

            w.close()
            await fut

            srv.close()
            await srv.wait_closed()

            self.assertEqual(TOTAL, N * 2 * len(DATA) + 14 * len(DATA))

        self.loop.run_until_complete(run())


class Test_AIO_TCP(_TestTCP, tb.AIOTestCase):
    pass


class _TestSSL(tb.SSLTestCase):

    def test_create_server_ssl_1(self):
        CNT = 0           # number of clients that were successful
        TOTAL_CNT = 25    # total number of clients that test will create
        TIMEOUT = 5.0     # timeout for this test

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

            def prog():
                try:
                    yield tb.starttls(client_sslctx)
                    yield tb.connect(addr)
                    yield tb.write(A_DATA)

                    data = yield tb.read(2)
                    self.assertEqual(data, b'OK')

                    yield tb.write(B_DATA)
                    data = yield tb.read(4)
                    self.assertEqual(data, b'SPAM')

                    yield tb.close()

                except Exception as ex:
                    self.loop.call_soon_threadsafe(fut.set_exception, ex)
                else:
                    self.loop.call_soon_threadsafe(fut.set_result, None)

            client = tb.tcp_client(prog)
            client.start()
            clients.append(client)

            await fut

        async def start_server():
            srv = await asyncio.start_server(
                handle_client,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                ssl=sslctx,
                loop=self.loop)

            try:
                srv_socks = srv.sockets
                self.assertTrue(srv_socks)

                addr = srv_socks[0].getsockname()

                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(test_client(addr))

                await asyncio.wait_for(
                    asyncio.gather(*tasks, loop=self.loop),
                    TIMEOUT, loop=self.loop)

            finally:
                self.loop.call_soon(srv.close)
                await srv.wait_closed()

        with self._silence_eof_received_warning():
            self.loop.run_until_complete(start_server())

        self.assertEqual(CNT, TOTAL_CNT)

        for client in clients:
            client.stop()

    def test_create_connection_ssl_1(self):
        CNT = 0
        TOTAL_CNT = 25

        A_DATA = b'A' * 1024 * 1024
        B_DATA = b'B' * 1024 * 1024

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()

        def server():
            yield tb.starttls(
                sslctx,
                server_side=True)

            data = yield tb.read(len(A_DATA))
            self.assertEqual(data, A_DATA)
            yield tb.write(b'OK')

            data = yield tb.read(len(B_DATA))
            self.assertEqual(data, B_DATA)
            yield tb.write(b'SPAM')

            yield tb.close()

        async def client(addr):
            reader, writer = await asyncio.open_connection(
                *addr,
                ssl=client_sslctx,
                server_hostname='',
                loop=self.loop)

            writer.write(A_DATA)
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(B_DATA)
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            nonlocal CNT
            CNT += 1

            writer.close()

        def run(coro):
            nonlocal CNT
            CNT = 0

            srv = tb.tcp_server(server,
                                max_clients=TOTAL_CNT,
                                backlog=TOTAL_CNT)
            srv.start()

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(coro(srv.addr))

            self.loop.run_until_complete(
                asyncio.gather(*tasks, loop=self.loop))
            srv.join()
            self.assertEqual(CNT, TOTAL_CNT)

        with self._silence_eof_received_warning():
            run(client)


class Test_UV_TCPSSL(_TestSSL, tb.UVTestCase):
    pass


class Test_AIO_TCPSSL(_TestSSL, tb.AIOTestCase):
    pass
