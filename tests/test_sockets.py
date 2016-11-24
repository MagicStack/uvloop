import asyncio
import select
import socket
import sys
import unittest

from uvloop import _testbase as tb


_SIZE = 1024 * 1024


class _TestSockets:

    async def recv_all(self, sock, nbytes):
        buf = b''
        while len(buf) < nbytes:
            buf += await self.loop.sock_recv(sock, nbytes - len(buf))
        return buf

    def test_socket_connect_recv_send(self):
        if self.is_asyncio_loop() and sys.version_info[:3] == (3, 5, 2):
            # See https://github.com/python/asyncio/pull/366 for details.
            raise unittest.SkipTest()

        def srv_gen():
            yield tb.write(b'helo')
            data = yield tb.read(4 * _SIZE)
            self.assertEqual(data, b'ehlo' * _SIZE)
            yield tb.write(b'O')
            yield tb.write(b'K')

        # We use @asyncio.coroutine & `yield from` to test
        # the compatibility of Cython's 'async def' coroutines.
        @asyncio.coroutine
        def client(sock, addr):
            yield from self.loop.sock_connect(sock, addr)
            data = yield from self.recv_all(sock, 4)
            self.assertEqual(data, b'helo')
            yield from self.loop.sock_sendall(sock, b'ehlo' * _SIZE)
            data = yield from self.recv_all(sock, 2)
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
                self.loop.run_until_complete(
                    self.loop.sock_recv(sock, 0))

            with self.assertRaisesRegex(ValueError, 'must be non-blocking'):
                self.loop.run_until_complete(
                    self.loop.sock_sendall(sock, b''))

            with self.assertRaisesRegex(ValueError, 'must be non-blocking'):
                self.loop.run_until_complete(
                    self.loop.sock_accept(sock))

            with self.assertRaisesRegex(ValueError, 'must be non-blocking'):
                self.loop.run_until_complete(
                    self.loop.sock_connect(sock, (b'', 0)))


class TestUVSockets(_TestSockets, tb.UVTestCase):

    @unittest.skipUnless(hasattr(select, 'epoll'), 'Linux only test')
    def test_socket_sync_remove(self):
        # See https://github.com/MagicStack/uvloop/issues/61 for details

        sock = socket.socket()
        epoll = select.epoll.fromfd(self.loop._get_backend_id())

        try:
            cb = lambda: None

            sock.bind(('127.0.0.1', 0))
            sock.listen(0)
            fd = sock.fileno()
            self.loop.add_reader(fd, cb)
            self.loop.run_until_complete(asyncio.sleep(0.01, loop=self.loop))
            self.loop.remove_reader(fd)
            with self.assertRaises(FileNotFoundError):
                epoll.modify(fd, 0)

        finally:
            sock.close()
            self.loop.close()
            epoll.close()

class TestAIOSockets(_TestSockets, tb.AIOTestCase):
    pass
