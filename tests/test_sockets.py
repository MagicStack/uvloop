import socket

from uvloop import _testbase as tb


_SIZE = 1024 * 1024


class _TestSockets:

    async def recv_all(self, sock, nbytes):
        buf = b''
        while len(buf) < nbytes:
            buf += await self.loop.sock_recv(sock, nbytes - len(buf))
        return buf

    def test_socket_connect_recv_send(self):
        def srv_gen():
            yield tb.write(b'helo')
            data = yield tb.read(4 * _SIZE)
            self.assertEqual(data, b'ehlo' * _SIZE)
            yield tb.write(b'O')
            yield tb.write(b'K')

        async def client(sock, addr):
            await self.loop.sock_connect(sock, addr)
            data = await self.recv_all(sock, 4)
            self.assertEqual(data, b'helo')
            await self.loop.sock_sendall(sock, b'ehlo' * _SIZE)
            data = await self.recv_all(sock, 2)
            self.assertEqual(data, b'OK')

        with tb.tcp_server(srv_gen) as srv:

            sock = socket.socket()
            with sock:
                sock.setblocking(False)
                self.loop.run_until_complete(client(sock, srv.addr))

    def test_socket_accept_recv_send(self):
        async def server():
            sock = socket.socket()
            sock.setblocking(False)

            with sock:
                sock.bind(('127.0.0.1', 0))
                sock.listen()

                fut = self.loop.run_in_executor(None, client,
                                                sock.getsockname())

                client_sock, _ = await self.loop.sock_accept(sock)

                with client_sock:
                    data = await self.recv_all(client_sock, _SIZE)
                    self.assertEqual(data, b'a' * _SIZE)

                await fut

        def client(addr):
            sock = socket.socket()
            with sock:
                sock.connect(addr)
                sock.sendall(b'a' * _SIZE)

        self.loop.run_until_complete(server())

    def test_socket_failed_connect(self):
        sock = socket.socket()
        with sock:
            sock.bind(('127.0.0.1', 0))
            addr = sock.getsockname()

        async def run():
            sock = socket.socket()
            with sock:
                sock.setblocking(False)
                with self.assertRaises(ConnectionRefusedError):
                    await self.loop.sock_connect(sock, addr)

        self.loop.run_until_complete(run())

    def test_socket_blocking_error(self):
        self.loop.set_debug(True)
        sock = socket.socket()

        with sock:
            with self.assertRaisesRegex(ValueError, 'must be non-blocking'):
                self.loop.sock_recv(sock, 0)

            with self.assertRaisesRegex(ValueError, 'must be non-blocking'):
                self.loop.sock_sendall(sock, b'')

            with self.assertRaisesRegex(ValueError, 'must be non-blocking'):
                self.loop.sock_accept(sock)

            with self.assertRaisesRegex(ValueError, 'must be non-blocking'):
                self.loop.sock_connect(sock, (b'', 0))


class TestUVSockets(_TestSockets, tb.UVTestCase):
    pass


class TestAIOSockets(_TestSockets, tb.AIOTestCase):
    pass
