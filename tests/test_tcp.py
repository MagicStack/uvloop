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

        async def start_server():
            try:
                srv = await asyncio.start_server(
                    handle_client,
                    '127.0.0.1', 0,
                    family=socket.AF_INET,
                    loop=self.loop)

                try:
                    addr = srv.sockets[0].getsockname()

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

            except:
                self.loop.stop()  # We don't want this test to stuck when
                                  # it fails.
                raise

        self.loop.create_task(start_server())
        self.loop.run_forever()
        self.assertEqual(CNT, TOTAL_CNT)


class Test_UV_TCP(_TestTCP, tb.UVTestCase):
    pass


class Test_AIO_TCP(_TestTCP, tb.AIOTestCase):
    pass
