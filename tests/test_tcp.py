import asyncio
import socket
import uvloop

from uvloop import _testbase as tb


class _TestTCP:
    def test_create_server_1(self):
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
            sock = socket.socket()
            with sock:
                sock.setblocking(False)
                await self.loop.sock_connect(sock, addr)

                await self.loop.sock_sendall(sock, b'AAAA')
                data = await self.loop.sock_recv(sock, 2)
                self.assertEqual(data, b'OK')

                await self.loop.sock_sendall(sock, b'BBBB')
                data = await self.loop.sock_recv(sock, 4)
                self.assertEqual(data, b'SPAM')

        async def start_server():
            nonlocal CNT
            CNT = 0

            try:
                srv = await asyncio.start_server(
                    handle_client,
                    ('127.0.0.1', 'localhost'), 0,
                    family=socket.AF_INET,
                    loop=self.loop)

                try:
                    srv_socks = srv.sockets
                    self.assertTrue(srv_socks)

                    addr = srv_socks[0].getsockname()

                    tasks = []
                    for _ in range(TOTAL_CNT):
                        tasks.append(test_client(addr))

                    try:
                        await asyncio.wait_for(
                            asyncio.gather(*tasks, loop=self.loop),
                            TIMEOUT, loop=self.loop)
                    finally:
                        self.loop.stop()

                finally:
                    self.loop.call_soon(srv.close)
                    await srv.wait_closed()

                    # Check that the server cleaned-up proxy-sockets
                    for srv_sock in srv_socks:
                        self.assertEqual(srv_sock.fileno(), -1)

            except:
                self.loop.stop()  # We don't want this test to stuck when
                                  # it fails.
                raise

        async def start_server_sock():
            nonlocal CNT
            CNT = 0

            sock = socket.socket()
            sock.bind(('127.0.0.1', 0))
            addr = sock.getsockname()
            try:
                srv = await asyncio.start_server(
                    handle_client,
                    None, None,
                    family=socket.AF_INET,
                    loop=self.loop,
                    sock=sock)

                try:
                    srv_socks = srv.sockets
                    self.assertTrue(srv_socks)

                    tasks = []
                    for _ in range(TOTAL_CNT):
                        tasks.append(test_client(addr))

                    try:
                        await asyncio.wait_for(
                            asyncio.gather(*tasks, loop=self.loop),
                            TIMEOUT, loop=self.loop)
                    finally:
                        self.loop.stop()

                finally:
                    srv.close()

                    # Check that the server cleaned-up proxy-sockets
                    for srv_sock in srv_socks:
                        self.assertEqual(srv_sock.fileno(), -1)

            except:
                self.loop.stop()  # We don't want this test to stuck when
                                  # it fails.
                raise

        self.loop.create_task(start_server())
        self.loop.run_forever()
        self.assertEqual(CNT, TOTAL_CNT)

        self.loop.create_task(start_server_sock())
        self.loop.run_forever()
        self.assertEqual(CNT, TOTAL_CNT)

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
                                backlog=TOTAL_CNT,
                                timeout=5)
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
                                backlog=TOTAL_CNT,
                                timeout=5)
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

            sock = t.get_extra_info('socket')
            self.assertTrue(isinstance(sock, socket.socket))

            self.assertEqual(t.get_extra_info('sockname'),
                             sock.getsockname())

            self.assertEqual(t.get_extra_info('peername'),
                             sock.getpeername())

            t.write(b'OK')  # We want server to fail.
            t.close()

            await fut

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
    pass


class Test_AIO_TCP(_TestTCP, tb.AIOTestCase):
    pass
