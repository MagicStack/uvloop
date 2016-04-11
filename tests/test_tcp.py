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
                    srv.close()

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


class Test_UV_TCP(_TestTCP, tb.UVTestCase):
    pass


class Test_AIO_TCP(_TestTCP, tb.AIOTestCase):
    pass
