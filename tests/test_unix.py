import asyncio
import os
import socket
import tempfile

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
                    sock_name,
                    loop=self.loop)

                try:
                    srv_socks = srv.sockets
                    self.assertTrue(srv_socks)

                    tasks = []
                    for _ in range(TOTAL_CNT):
                        tasks.append(test_client(sock_name))

                    await asyncio.wait_for(
                        asyncio.gather(*tasks, loop=self.loop),
                        TIMEOUT, loop=self.loop)

                finally:
                    self.loop.call_soon(srv.close)
                    await srv.wait_closed()

                    # Check that the server cleaned-up proxy-sockets
                    for srv_sock in srv_socks:
                        self.assertEqual(srv_sock.fileno(), -1)

                # asyncio doesn't cleanup the sock file
                self.assertTrue(os.path.exists(sock_name))

        async def start_server_sock():
            nonlocal CNT
            CNT = 0

            with tempfile.TemporaryDirectory() as td:
                sock_name = os.path.join(td, 'sock')
                sock = socket.socket(socket.AF_UNIX)
                sock.bind(sock_name)

                srv = await asyncio.start_unix_server(
                    handle_client,
                    None,
                    loop=self.loop,
                    sock=sock)

                try:
                    srv_socks = srv.sockets
                    self.assertTrue(srv_socks)

                    tasks = []
                    for _ in range(TOTAL_CNT):
                        tasks.append(test_client(sock_name))

                    await asyncio.wait_for(
                        asyncio.gather(*tasks, loop=self.loop),
                        TIMEOUT, loop=self.loop)

                finally:
                    self.loop.call_soon(srv.close)
                    await srv.wait_closed()

                    # Check that the server cleaned-up proxy-sockets
                    for srv_sock in srv_socks:
                        self.assertEqual(srv_sock.fileno(), -1)

                # asyncio doesn't cleanup the sock file
                self.assertTrue(os.path.exists(sock_name))

        self.loop.run_until_complete(start_server())
        self.assertEqual(CNT, TOTAL_CNT)

        self.loop.run_until_complete(start_server_sock())
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

    def test_create_unix_connection_1(self):
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
            reader, writer = await asyncio.open_unix_connection(
                addr,
                loop=self.loop)

            writer.write(b'AAAA')
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(b'BBBB')
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            nonlocal CNT
            CNT += 1

            writer.close()

        async def client_2(addr):
            sock = socket.socket(socket.AF_UNIX)
            sock.connect(addr)
            reader, writer = await asyncio.open_unix_connection(
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
                                family=socket.AF_UNIX,
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

    def test_create_unix_connection_2(self):
        with tempfile.NamedTemporaryFile() as tmp:
            path = tmp.name

        async def client():
            reader, writer = await asyncio.open_unix_connection(
                path,
                loop=self.loop)

        async def runner():
            with self.assertRaises(FileNotFoundError):
                await client()

        self.loop.run_until_complete(runner())

    def test_create_unix_connection_3(self):
        CNT = 0
        TOTAL_CNT = 100

        def server():
            data = yield tb.read(4)
            self.assertEqual(data, b'AAAA')
            yield tb.close()

        async def client(addr):
            reader, writer = await asyncio.open_unix_connection(
                addr,
                loop=self.loop)

            sock = writer._transport.get_extra_info('socket')
            self.assertEqual(sock.family, socket.AF_UNIX)

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
                                family=socket.AF_UNIX,
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

    def test_create_unix_connection_4(self):
        sock = socket.socket(socket.AF_UNIX)
        sock.close()

        async def client():
            reader, writer = await asyncio.open_unix_connection(
                sock=sock,
                loop=self.loop)

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
            await asyncio.sleep(0.1, loop=self.loop)

        self.loop.run_until_complete(client())

        self.assertEqual(len(excs), 1)
        self.assertIn(excs[0].__class__,
                      (BrokenPipeError, ConnectionResetError))

    def test_transport_fromsock_get_extra_info(self):
        async def test(sock):
            t, _ = await self.loop.create_unix_connection(
                asyncio.Protocol,
                None,
                sock=sock)

            self.assertIs(t.get_extra_info('socket'), sock)
            t.close()

        s1, s2 = socket.socketpair(socket.AF_UNIX)
        with s1, s2:
            self.loop.run_until_complete(test(s1))

    def test_transport_unclosed_warning(self):
        async def test(sock):
            return await self.loop.create_unix_connection(
                asyncio.Protocol,
                None,
                sock=sock)

        with self.assertWarnsRegex(ResourceWarning, 'unclosed'):
            s1, s2 = socket.socketpair(socket.AF_UNIX)
            with s1, s2:
                self.loop.run_until_complete(test(s1))
            self.loop.close()


class Test_UV_Unix(_TestUnix, tb.UVTestCase):
    pass


class Test_AIO_Unix(_TestUnix, tb.AIOTestCase):
    pass


class _TestSSL(tb.SSLTestCase):

    def test_create_unix_server_ssl_1(self):
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

            client = tb.tcp_client(prog, family=socket.AF_UNIX)
            client.start()
            clients.append(client)

            await fut

        async def start_server():
            with tempfile.TemporaryDirectory() as td:
                sock_name = os.path.join(td, 'sock')

                srv = await asyncio.start_unix_server(
                    handle_client,
                    sock_name,
                    ssl=sslctx,
                    loop=self.loop)

                try:
                    tasks = []
                    for _ in range(TOTAL_CNT):
                        tasks.append(test_client(sock_name))

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

    def test_create_unix_connection_ssl_1(self):
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
            reader, writer = await asyncio.open_unix_connection(
                addr,
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
                                family=socket.AF_UNIX,
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


class Test_UV_UnixSSL(_TestSSL, tb.UVTestCase):
    pass


class Test_AIO_UnixSSL(_TestSSL, tb.AIOTestCase):
    pass
