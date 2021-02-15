import asyncio
import asyncio.sslproto
import gc
import os
import select
import socket
import unittest.mock
import ssl
import sys
import threading
import time
import weakref

from OpenSSL import SSL as openssl_ssl
from uvloop import _testbase as tb


SSL_HANDSHAKE_TIMEOUT = 15.0


class MyBaseProto(asyncio.Protocol):
    connected = None
    done = None

    def __init__(self, loop=None):
        self.transport = None
        self.state = 'INITIAL'
        self.nbytes = 0
        if loop is not None:
            self.connected = asyncio.Future(loop=loop)
            self.done = asyncio.Future(loop=loop)

    def connection_made(self, transport):
        self.transport = transport
        assert self.state == 'INITIAL', self.state
        self.state = 'CONNECTED'
        if self.connected:
            self.connected.set_result(None)

    def data_received(self, data):
        assert self.state == 'CONNECTED', self.state
        self.nbytes += len(data)

    def eof_received(self):
        assert self.state == 'CONNECTED', self.state
        self.state = 'EOF'

    def connection_lost(self, exc):
        assert self.state in ('CONNECTED', 'EOF'), self.state
        self.state = 'CLOSED'
        if self.done:
            self.done.set_result(None)


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

            if self.implementation == 'uvloop':
                tr = writer.transport
                sock = tr.get_extra_info('socket')
                self.assertTrue(
                    sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY))

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

            self.assertEqual(sock.fileno(), -1)
            self.assertEqual(sock._io_refs, 0)
            self.assertTrue(sock._closed)

        async def start_server():
            nonlocal CNT
            CNT = 0

            srv = await asyncio.start_server(
                handle_client,
                ('127.0.0.1', 'localhost'), 0,
                family=socket.AF_INET)

            srv_socks = srv.sockets
            self.assertTrue(srv_socks)
            self.assertTrue(srv.is_serving())

            addr = srv_socks[0].getsockname()

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(test_client(addr))

            await asyncio.wait_for(asyncio.gather(*tasks), TIMEOUT)

            self.loop.call_soon(srv.close)
            await srv.wait_closed()

            # Check that the server cleaned-up proxy-sockets
            for srv_sock in srv_socks:
                self.assertEqual(srv_sock.fileno(), -1)

            self.assertFalse(srv.is_serving())

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
                sock=sock)

            self.assertIs(srv.get_loop(), self.loop)

            srv_socks = srv.sockets
            self.assertTrue(srv_socks)
            self.assertTrue(srv.is_serving())

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(test_client(addr))

            await asyncio.wait_for(asyncio.gather(*tasks), TIMEOUT)

            srv.close()
            await srv.wait_closed()

            # Check that the server cleaned-up proxy-sockets
            for srv_sock in srv_socks:
                self.assertEqual(srv_sock.fileno(), -1)

            self.assertFalse(srv.is_serving())

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
                self.assertTrue(srv.is_serving())

                host, port = srv_socks[0].getsockname()
                self.assertNotEqual(0, port)

                self.loop.call_soon(srv.close)
                await srv.wait_closed()

                # Check that the server cleaned-up proxy-sockets
                for srv_sock in srv_socks:
                    self.assertEqual(srv_sock.fileno(), -1)

                self.assertFalse(srv.is_serving())

        self.loop.run_until_complete(start_server_ephemeral_ports())

    def test_create_server_4(self):
        sock = socket.socket()
        sock.bind(('127.0.0.1', 0))

        with sock:
            addr = sock.getsockname()

            with self.assertRaisesRegex(OSError,
                                        r"error while attempting.*\('127.*: "
                                        r"address already in use"):

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

    def test_create_server_7(self):
        # Test that create_server() stores a hard ref to the server object
        # somewhere in the loop.  In asyncio it so happens that
        # loop.sock_accept() has a reference to the server object so it
        # never gets GCed.

        class Proto(asyncio.Protocol):
            def connection_made(self, tr):
                self.tr = tr
                self.tr.write(b'hello')

        async def test():
            port = tb.find_free_port()
            srv = await self.loop.create_server(Proto, '127.0.0.1', port)
            wsrv = weakref.ref(srv)
            del srv

            gc.collect()
            gc.collect()
            gc.collect()

            s = socket.socket(socket.AF_INET)
            with s:
                s.setblocking(False)
                await self.loop.sock_connect(s, ('127.0.0.1', port))
                d = await self.loop.sock_recv(s, 100)
                self.assertEqual(d, b'hello')

            srv = wsrv()
            srv.close()
            await srv.wait_closed()
            del srv

            # Let all transports shutdown.
            await asyncio.sleep(0.1)

            gc.collect()
            gc.collect()
            gc.collect()

            self.assertIsNone(wsrv())

        self.loop.run_until_complete(test())

    def test_create_server_8(self):
        with self.assertRaisesRegex(
                ValueError, 'ssl_handshake_timeout is only meaningful'):
            self.loop.run_until_complete(
                self.loop.create_server(
                    lambda: None, host='::', port=0, ssl_handshake_timeout=10))

    def test_create_server_9(self):
        async def handle_client(reader, writer):
            pass

        async def start_server():
            srv = await asyncio.start_server(
                handle_client,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                start_serving=False)

            await srv.start_serving()
            self.assertTrue(srv.is_serving())

            # call start_serving again
            await srv.start_serving()
            self.assertTrue(srv.is_serving())

            srv.close()
            await srv.wait_closed()
            self.assertFalse(srv.is_serving())

        self.loop.run_until_complete(start_server())

    def test_create_server_10(self):
        async def handle_client(reader, writer):
            pass

        async def start_server():
            srv = await asyncio.start_server(
                handle_client,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                start_serving=False)

            async with srv:
                fut = asyncio.ensure_future(srv.serve_forever())
                await asyncio.sleep(0)
                self.assertTrue(srv.is_serving())

                fut.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await fut
                self.assertFalse(srv.is_serving())

        self.loop.run_until_complete(start_server())

    def test_create_connection_open_con_addr(self):
        async def client(addr):
            reader, writer = await asyncio.open_connection(*addr)

            writer.write(b'AAAA')
            self.assertEqual(await reader.readexactly(2), b'OK')

            re = r'(a bytes-like object)|(must be byte-ish)'
            with self.assertRaisesRegex(TypeError, re):
                writer.write('AAAA')

            writer.write(b'BBBB')
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            if self.implementation == 'uvloop':
                tr = writer.transport
                sock = tr.get_extra_info('socket')
                self.assertTrue(
                    sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY))

            writer.close()
            await self.wait_closed(writer)

        self._test_create_connection_1(client)

    def test_create_connection_open_con_sock(self):
        async def client(addr):
            sock = socket.socket()
            sock.connect(addr)
            reader, writer = await asyncio.open_connection(sock=sock)

            writer.write(b'AAAA')
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(b'BBBB')
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            if self.implementation == 'uvloop':
                tr = writer.transport
                sock = tr.get_extra_info('socket')
                self.assertTrue(
                    sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY))

            writer.close()
            await self.wait_closed(writer)

        self._test_create_connection_1(client)

    def _test_create_connection_1(self, client):
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

            with self.tcp_server(server,
                                 max_clients=TOTAL_CNT,
                                 backlog=TOTAL_CNT) as srv:
                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(coro(srv.addr))

                self.loop.run_until_complete(asyncio.gather(*tasks))

            self.assertEqual(CNT, TOTAL_CNT)

        run(client_wrapper)

    def test_create_connection_2(self):
        sock = socket.socket()
        with sock:
            sock.bind(('127.0.0.1', 0))
            addr = sock.getsockname()

        async def client():
            reader, writer = await asyncio.open_connection(*addr)
            writer.close()
            await self.wait_closed(writer)

        async def runner():
            with self.assertRaises(ConnectionRefusedError):
                await client()

        self.loop.run_until_complete(runner())

    def test_create_connection_3(self):
        CNT = 0
        TOTAL_CNT = 100

        def server(sock):
            data = sock.recv_all(4)
            self.assertEqual(data, b'AAAA')
            sock.close()

        async def client(addr):
            reader, writer = await asyncio.open_connection(*addr)

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

            with self.tcp_server(server,
                                 max_clients=TOTAL_CNT,
                                 backlog=TOTAL_CNT) as srv:
                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(coro(srv.addr))

                self.loop.run_until_complete(asyncio.gather(*tasks))

            self.assertEqual(CNT, TOTAL_CNT)

        run(client)

    def test_create_connection_4(self):
        sock = socket.socket()
        sock.close()

        async def client():
            reader, writer = await asyncio.open_connection(sock=sock)
            writer.close()
            await self.wait_closed(writer)

        async def runner():
            with self.assertRaisesRegex(OSError, 'Bad file'):
                await client()

        self.loop.run_until_complete(runner())

    def test_create_connection_5(self):
        def server(sock):
            try:
                data = sock.recv_all(4)
            except ConnectionError:
                return
            self.assertEqual(data, b'AAAA')
            sock.send(b'OK')

        async def client(addr):
            fut = asyncio.ensure_future(
                self.loop.create_connection(asyncio.Protocol, *addr))
            await asyncio.sleep(0)
            fut.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await fut

        with self.tcp_server(server,
                             max_clients=1,
                             backlog=1) as srv:
            self.loop.run_until_complete(client(srv.addr))

    def test_create_connection_6(self):
        with self.assertRaisesRegex(
                ValueError, 'ssl_handshake_timeout is only meaningful'):
            self.loop.run_until_complete(
                self.loop.create_connection(
                    lambda: None, host='::', port=0, ssl_handshake_timeout=10))

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
            reader, writer = await asyncio.open_connection(*addr)

            writer.write(b'AAAA')
            data = await reader.readexactly(2)
            self.assertEqual(data, b'OK')

            writer.close()
            await self.wait_closed(writer)

        async def start_server():
            nonlocal CNT
            CNT = 0

            srv = await asyncio.start_server(
                handle_client,
                '127.0.0.1', 0,
                family=socket.AF_INET)

            srv_socks = srv.sockets
            self.assertTrue(srv_socks)

            addr = srv_socks[0].getsockname()

            tasks = []
            for _ in range(TOTAL_CNT):
                tasks.append(test_client(addr))

            await asyncio.wait_for(asyncio.gather(*tasks), TIMEOUT)

            srv.close()
            await srv.wait_closed()

        self.loop.run_until_complete(start_server())
        self.assertEqual(CNT, TOTAL_CNT)

    def test_tcp_handle_exception_in_connection_made(self):
        # Test that if connection_made raises an exception,
        # 'create_connection' still returns.

        # Silence error logging
        self.loop.set_exception_handler(lambda *args: None)

        fut = asyncio.Future()
        connection_lost_called = asyncio.Future()

        async def server(reader, writer):
            try:
                await reader.read()
            finally:
                writer.close()

        class Proto(asyncio.Protocol):
            def connection_made(self, tr):
                1 / 0

            def connection_lost(self, exc):
                connection_lost_called.set_result(exc)

        srv = self.loop.run_until_complete(asyncio.start_server(
            server,
            '127.0.0.1', 0,
            family=socket.AF_INET))

        async def runner():
            tr, pr = await asyncio.wait_for(
                self.loop.create_connection(
                    Proto, *srv.sockets[0].getsockname()),
                timeout=1.0)
            fut.set_result(None)
            tr.close()

        self.loop.run_until_complete(runner())
        srv.close()
        self.loop.run_until_complete(srv.wait_closed())
        self.loop.run_until_complete(fut)

        self.assertIsNone(
            self.loop.run_until_complete(connection_lost_called))

    def test_context_run_segfault(self):
        is_new = False
        done = self.loop.create_future()

        def server(sock):
            sock.sendall(b'hello')

        class Protocol(asyncio.Protocol):
            def __init__(self):
                self.transport = None

            def connection_made(self, transport):
                self.transport = transport

            def data_received(self, data):
                try:
                    self = weakref.ref(self)
                    nonlocal is_new
                    if is_new:
                        done.set_result(data)
                    else:
                        is_new = True
                        new_proto = Protocol()
                        self().transport.set_protocol(new_proto)
                        new_proto.connection_made(self().transport)
                        new_proto.data_received(data)
                except Exception as e:
                    done.set_exception(e)

        async def test(addr):
            await self.loop.create_connection(Protocol, *addr)
            data = await done
            self.assertEqual(data, b'hello')

        with self.tcp_server(server) as srv:
            self.loop.run_until_complete(test(srv.addr))


class Test_UV_TCP(_TestTCP, tb.UVTestCase):

    def test_create_server_buffered_1(self):
        SIZE = 123123
        eof = False
        fut = asyncio.Future()

        class Proto(asyncio.BaseProtocol):
            def connection_made(self, tr):
                self.tr = tr
                self.recvd = b''
                self.data = bytearray(50)
                self.buf = memoryview(self.data)

            def get_buffer(self, sizehint):
                return self.buf

            def buffer_updated(self, nbytes):
                self.recvd += self.buf[:nbytes]
                if self.recvd == b'a' * SIZE:
                    self.tr.write(b'hello')

            def eof_received(self):
                nonlocal eof
                eof = True

            def connection_lost(self, exc):
                fut.set_result(exc)

        async def test():
            port = tb.find_free_port()
            srv = await self.loop.create_server(Proto, '127.0.0.1', port)

            s = socket.socket(socket.AF_INET)
            with s:
                s.setblocking(False)
                await self.loop.sock_connect(s, ('127.0.0.1', port))
                await self.loop.sock_sendall(s, b'a' * SIZE)
                d = await self.loop.sock_recv(s, 100)
                self.assertEqual(d, b'hello')

            srv.close()
            await srv.wait_closed()

        self.loop.run_until_complete(test())
        self.loop.run_until_complete(fut)
        self.assertTrue(eof)
        self.assertIsNone(fut.result())

    def test_create_server_buffered_2(self):
        class ProtoExc(asyncio.BaseProtocol):
            def __init__(self):
                self._lost_exc = None

            def get_buffer(self, sizehint):
                1 / 0

            def buffer_updated(self, nbytes):
                pass

            def connection_lost(self, exc):
                self._lost_exc = exc

            def eof_received(self):
                pass

        class ProtoZeroBuf1(asyncio.BaseProtocol):
            def __init__(self):
                self._lost_exc = None

            def get_buffer(self, sizehint):
                return bytearray(0)

            def buffer_updated(self, nbytes):
                pass

            def connection_lost(self, exc):
                self._lost_exc = exc

            def eof_received(self):
                pass

        class ProtoZeroBuf2(asyncio.BaseProtocol):
            def __init__(self):
                self._lost_exc = None

            def get_buffer(self, sizehint):
                return memoryview(bytearray(0))

            def buffer_updated(self, nbytes):
                pass

            def connection_lost(self, exc):
                self._lost_exc = exc

            def eof_received(self):
                pass

        class ProtoUpdatedError(asyncio.BaseProtocol):
            def __init__(self):
                self._lost_exc = None

            def get_buffer(self, sizehint):
                return memoryview(bytearray(100))

            def buffer_updated(self, nbytes):
                raise RuntimeError('oups')

            def connection_lost(self, exc):
                self._lost_exc = exc

            def eof_received(self):
                pass

        async def test(proto_factory, exc_type, exc_re):
            port = tb.find_free_port()
            proto = proto_factory()
            srv = await self.loop.create_server(
                lambda: proto, '127.0.0.1', port)

            try:
                s = socket.socket(socket.AF_INET)
                with s:
                    s.setblocking(False)
                    await self.loop.sock_connect(s, ('127.0.0.1', port))
                    await self.loop.sock_sendall(s, b'a')
                    d = await self.loop.sock_recv(s, 100)
                    if not d:
                        raise ConnectionResetError
            except ConnectionResetError:
                pass
            else:
                self.fail("server didn't abort the connection")
                return
            finally:
                srv.close()
                await srv.wait_closed()

            if proto._lost_exc is None:
                self.fail("connection_lost() was not called")
                return

            with self.assertRaisesRegex(exc_type, exc_re):
                raise proto._lost_exc

        self.loop.set_exception_handler(lambda loop, ctx: None)

        self.loop.run_until_complete(
            test(ProtoExc, RuntimeError, 'unhandled error .* get_buffer'))

        self.loop.run_until_complete(
            test(ProtoZeroBuf1, RuntimeError, 'unhandled error .* get_buffer'))

        self.loop.run_until_complete(
            test(ProtoZeroBuf2, RuntimeError, 'unhandled error .* get_buffer'))

        self.loop.run_until_complete(
            test(ProtoUpdatedError, RuntimeError, r'^oups$'))

    def test_transport_get_extra_info(self):
        # This tests is only for uvloop.  asyncio should pass it
        # too in Python 3.6.

        fut = asyncio.Future()

        async def handle_client(reader, writer):
            with self.assertRaises(asyncio.IncompleteReadError):
                await reader.readexactly(4)
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

            if hasattr(t, 'get_protocol'):
                p2 = asyncio.Protocol()
                self.assertIs(t.get_protocol(), p)
                t.set_protocol(p2)
                self.assertIs(t.get_protocol(), p2)
                t.set_protocol(p)

            self.assertFalse(t._paused)
            self.assertTrue(t.is_reading())
            t.pause_reading()
            t.pause_reading()  # Check that it's OK to call it 2nd time.
            self.assertTrue(t._paused)
            self.assertFalse(t.is_reading())
            t.resume_reading()
            t.resume_reading()  # Check that it's OK to call it 2nd time.
            self.assertFalse(t._paused)
            self.assertTrue(t.is_reading())

            sock = t.get_extra_info('socket')
            self.assertIs(sock, t.get_extra_info('socket'))
            sockname = sock.getsockname()
            peername = sock.getpeername()

            with self.assertRaisesRegex(RuntimeError, 'is used by transport'):
                self.loop.add_writer(sock.fileno(), lambda: None)
            with self.assertRaisesRegex(RuntimeError, 'is used by transport'):
                self.loop.remove_writer(sock.fileno())
            with self.assertRaisesRegex(RuntimeError, 'is used by transport'):
                self.loop.add_reader(sock.fileno(), lambda: None)
            with self.assertRaisesRegex(RuntimeError, 'is used by transport'):
                self.loop.remove_reader(sock.fileno())

            self.assertEqual(t.get_extra_info('sockname'),
                             sockname)
            self.assertEqual(t.get_extra_info('peername'),
                             peername)

            t.write(b'OK')  # We want server to fail.

            self.assertFalse(t._closing)
            t.abort()
            self.assertTrue(t._closing)

            self.assertFalse(t.is_reading())
            # Check that pause_reading and resume_reading don't raise
            # errors if called after the transport is closed.
            t.pause_reading()
            t.resume_reading()

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
                family=socket.AF_INET)

            addr = srv.sockets[0].getsockname()
            await test_client(addr)

            srv.close()
            await srv.wait_closed()

        self.loop.run_until_complete(start_server())

    def test_create_server_float_backlog(self):
        # asyncio spits out a warning we cannot suppress

        async def runner(bl):
            await self.loop.create_server(
                asyncio.Protocol,
                None, 0, backlog=bl)

        for bl in (1.1, '1'):
            with self.subTest(backlog=bl):
                with self.assertRaisesRegex(TypeError, 'integer'):
                    self.loop.run_until_complete(runner(bl))

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
                family=socket.AF_INET)

            addr = srv.sockets[0].getsockname()
            r, w = await asyncio.open_connection(*addr)

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
            await self.wait_closed(w)

            srv.close()
            await srv.wait_closed()

            self.assertEqual(TOTAL, N * 2 * len(DATA) + 14 * len(DATA))

        self.loop.run_until_complete(run())

    @unittest.skipIf(sys.version_info[:3] >= (3, 8, 0),
                     "3.8 has a different method of GCing unclosed streams")
    def test_tcp_handle_unclosed_gc(self):
        fut = self.loop.create_future()

        async def server(reader, writer):
            writer.transport.abort()
            fut.set_result(True)

        async def run():
            addr = srv.sockets[0].getsockname()
            await asyncio.open_connection(*addr)
            await fut
            srv.close()
            await srv.wait_closed()

        srv = self.loop.run_until_complete(asyncio.start_server(
            server,
            '127.0.0.1', 0,
            family=socket.AF_INET))

        if self.loop.get_debug():
            rx = r'unclosed resource <TCP.*; ' \
                 r'object created at(.|\n)*test_tcp_handle_unclosed_gc'
        else:
            rx = r'unclosed resource <TCP.*'

        with self.assertWarnsRegex(ResourceWarning, rx):
            self.loop.create_task(run())
            self.loop.run_until_complete(srv.wait_closed())
            self.loop.run_until_complete(asyncio.sleep(0.1))

            srv = None
            gc.collect()
            gc.collect()
            gc.collect()

            self.loop.run_until_complete(asyncio.sleep(0.1))

        # Since one TCPTransport handle wasn't closed correctly,
        # we need to disable this check:
        self.skip_unclosed_handles_check()

    def test_tcp_handle_abort_in_connection_made(self):
        async def server(reader, writer):
            try:
                await reader.read()
            finally:
                writer.close()

        class Proto(asyncio.Protocol):
            def connection_made(self, tr):
                tr.abort()

        srv = self.loop.run_until_complete(asyncio.start_server(
            server,
            '127.0.0.1', 0,
            family=socket.AF_INET))

        async def runner():
            tr, pr = await asyncio.wait_for(
                self.loop.create_connection(
                    Proto, *srv.sockets[0].getsockname()),
                timeout=1.0)

            # Asyncio would return a closed socket, which we
            # can't do: the transport was aborted, hence there
            # is no FD to attach a socket to (to make
            # get_extra_info() work).
            self.assertIsNone(tr.get_extra_info('socket'))
            tr.close()

        self.loop.run_until_complete(runner())
        srv.close()
        self.loop.run_until_complete(srv.wait_closed())

    def test_connect_accepted_socket_ssl_args(self):
        with self.assertRaisesRegex(
                ValueError, 'ssl_handshake_timeout is only meaningful'):
            with socket.socket() as s:
                self.loop.run_until_complete(
                    self.loop.connect_accepted_socket(
                        (lambda: None),
                        s,
                        ssl_handshake_timeout=SSL_HANDSHAKE_TIMEOUT
                    )
                )

    def test_connect_accepted_socket(self, server_ssl=None, client_ssl=None):
        loop = self.loop

        class MyProto(MyBaseProto):

            def connection_lost(self, exc):
                super().connection_lost(exc)
                loop.call_soon(loop.stop)

            def data_received(self, data):
                super().data_received(data)
                self.transport.write(expected_response)

        lsock = socket.socket(socket.AF_INET)
        lsock.bind(('127.0.0.1', 0))
        lsock.listen(1)
        addr = lsock.getsockname()

        message = b'test data'
        response = None
        expected_response = b'roger'

        def client():
            nonlocal response
            try:
                csock = socket.socket(socket.AF_INET)
                if client_ssl is not None:
                    csock = client_ssl.wrap_socket(csock)
                csock.connect(addr)
                csock.sendall(message)
                response = csock.recv(99)
                csock.close()
            except Exception as exc:
                print(
                    "Failure in client thread in test_connect_accepted_socket",
                    exc)

        thread = threading.Thread(target=client, daemon=True)
        thread.start()

        conn, _ = lsock.accept()
        proto = MyProto(loop=loop)
        proto.loop = loop

        extras = {}
        if server_ssl:
            extras = dict(ssl_handshake_timeout=SSL_HANDSHAKE_TIMEOUT)

        f = loop.create_task(
            loop.connect_accepted_socket(
                (lambda: proto), conn, ssl=server_ssl,
                **extras))
        loop.run_forever()
        conn.close()
        lsock.close()

        thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(proto.state, 'CLOSED')
        self.assertEqual(proto.nbytes, len(message))
        self.assertEqual(response, expected_response)
        tr, _ = f.result()

        if server_ssl:
            self.assertIn('SSL', tr.__class__.__name__)

        tr.close()
        # let it close
        self.loop.run_until_complete(asyncio.sleep(0.1))

    @unittest.skipUnless(hasattr(socket, 'AF_UNIX'), 'no Unix sockets')
    def test_create_connection_wrong_sock(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        with sock:
            coro = self.loop.create_connection(MyBaseProto, sock=sock)
            with self.assertRaisesRegex(ValueError,
                                        'A Stream Socket was expected'):
                self.loop.run_until_complete(coro)

    @unittest.skipUnless(hasattr(socket, 'AF_UNIX'), 'no Unix sockets')
    def test_create_server_wrong_sock(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        with sock:
            coro = self.loop.create_server(MyBaseProto, sock=sock)
            with self.assertRaisesRegex(ValueError,
                                        'A Stream Socket was expected'):
                self.loop.run_until_complete(coro)

    @unittest.skipUnless(hasattr(socket, 'SOCK_NONBLOCK'),
                         'no socket.SOCK_NONBLOCK (linux only)')
    def test_create_server_stream_bittype(self):
        sock = socket.socket(
            socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK)
        with sock:
            coro = self.loop.create_server(lambda: None, sock=sock)
            srv = self.loop.run_until_complete(coro)
            srv.close()
            self.loop.run_until_complete(srv.wait_closed())

    def test_flowcontrol_mixin_set_write_limits(self):
        async def client(addr):
            paused = False

            class Protocol(asyncio.Protocol):
                def pause_writing(self):
                    nonlocal paused
                    paused = True

                def resume_writing(self):
                    nonlocal paused
                    paused = False

            t, p = await self.loop.create_connection(Protocol, *addr)

            t.write(b'q' * 512)
            self.assertEqual(t.get_write_buffer_size(), 512)

            t.set_write_buffer_limits(low=16385)
            self.assertFalse(paused)
            self.assertEqual(t.get_write_buffer_limits(), (16385, 65540))

            with self.assertRaisesRegex(ValueError, 'high.*must be >= low'):
                t.set_write_buffer_limits(high=0, low=1)

            t.set_write_buffer_limits(high=1024, low=128)
            self.assertFalse(paused)
            self.assertEqual(t.get_write_buffer_limits(), (128, 1024))

            t.set_write_buffer_limits(high=256, low=128)
            self.assertTrue(paused)
            self.assertEqual(t.get_write_buffer_limits(), (128, 256))

            t.close()

        with self.tcp_server(lambda sock: sock.recv_all(1),
                             max_clients=1,
                             backlog=1) as srv:
            self.loop.run_until_complete(client(srv.addr))


class Test_AIO_TCP(_TestTCP, tb.AIOTestCase):
    pass


class _TestSSL(tb.SSLTestCase):

    ONLYCERT = tb._cert_fullname(__file__, 'ssl_cert.pem')
    ONLYKEY = tb._cert_fullname(__file__, 'ssl_key.pem')

    PAYLOAD_SIZE = 1024 * 100
    TIMEOUT = 60

    def test_create_server_ssl_1(self):
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
            fut = asyncio.Future()

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
                    self.loop.call_soon_threadsafe(fut.set_exception, ex)
                else:
                    self.loop.call_soon_threadsafe(fut.set_result, None)

            client = self.tcp_client(prog)
            client.start()
            clients.append(client)

            await fut

        async def start_server():
            extras = dict(ssl_handshake_timeout=SSL_HANDSHAKE_TIMEOUT)

            srv = await asyncio.start_server(
                handle_client,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                ssl=sslctx,
                **extras)

            try:
                srv_socks = srv.sockets
                self.assertTrue(srv_socks)

                addr = srv_socks[0].getsockname()

                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(test_client(addr))

                await asyncio.wait_for(asyncio.gather(*tasks), TIMEOUT)

            finally:
                self.loop.call_soon(srv.close)
                await srv.wait_closed()

        with self._silence_eof_received_warning():
            self.loop.run_until_complete(start_server())

        self.assertEqual(CNT, TOTAL_CNT)

        for client in clients:
            client.stop()

    def test_create_connection_ssl_1(self):
        if self.implementation == 'asyncio':
            # Don't crash on asyncio errors
            self.loop.set_exception_handler(None)

        CNT = 0
        TOTAL_CNT = 25

        A_DATA = b'A' * 1024 * 1024
        B_DATA = b'B' * 1024 * 1024

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()

        def server(sock):
            sock.starttls(
                sslctx,
                server_side=True)

            data = sock.recv_all(len(A_DATA))
            self.assertEqual(data, A_DATA)
            sock.send(b'OK')

            data = sock.recv_all(len(B_DATA))
            self.assertEqual(data, B_DATA)
            sock.send(b'SPAM')

            sock.close()

        async def client(addr):
            extras = dict(ssl_handshake_timeout=SSL_HANDSHAKE_TIMEOUT)

            reader, writer = await asyncio.open_connection(
                *addr,
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

        async def client_sock(addr):
            sock = socket.socket()
            sock.connect(addr)
            reader, writer = await asyncio.open_connection(
                sock=sock,
                ssl=client_sslctx,
                server_hostname='')

            writer.write(A_DATA)
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(B_DATA)
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            nonlocal CNT
            CNT += 1

            writer.close()
            await self.wait_closed(writer)
            sock.close()

        def run(coro):
            nonlocal CNT
            CNT = 0

            with self.tcp_server(server,
                                 max_clients=TOTAL_CNT,
                                 backlog=TOTAL_CNT) as srv:
                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(coro(srv.addr))

                self.loop.run_until_complete(asyncio.gather(*tasks))

            self.assertEqual(CNT, TOTAL_CNT)

        with self._silence_eof_received_warning():
            run(client)

        with self._silence_eof_received_warning():
            run(client_sock)

    def test_create_connection_ssl_slow_handshake(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        client_sslctx = self._create_client_ssl_context()

        # silence error logger
        self.loop.set_exception_handler(lambda *args: None)

        def server(sock):
            try:
                sock.recv_all(1024 * 1024)
            except ConnectionAbortedError:
                pass
            finally:
                sock.close()

        async def client(addr):
            reader, writer = await asyncio.open_connection(
                *addr,
                ssl=client_sslctx,
                server_hostname='',
                ssl_handshake_timeout=1.0)
            writer.close()
            await self.wait_closed(writer)

        with self.tcp_server(server,
                             max_clients=1,
                             backlog=1) as srv:

            with self.assertRaisesRegex(
                    ConnectionAbortedError,
                    r'SSL handshake.*is taking longer'):

                self.loop.run_until_complete(client(srv.addr))

    def test_create_connection_ssl_failed_certificate(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        # silence error logger
        self.loop.set_exception_handler(lambda *args: None)

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context(disable_verify=False)

        def server(sock):
            try:
                sock.starttls(
                    sslctx,
                    server_side=True)
                sock.connect()
            except (ssl.SSLError, OSError):
                pass
            finally:
                sock.close()

        async def client(addr):
            reader, writer = await asyncio.open_connection(
                *addr,
                ssl=client_sslctx,
                server_hostname='',
                ssl_handshake_timeout=1.0)
            writer.close()
            await self.wait_closed(writer)

        with self.tcp_server(server,
                             max_clients=1,
                             backlog=1) as srv:

            with self.assertRaises(ssl.SSLCertVerificationError):
                self.loop.run_until_complete(client(srv.addr))

    def test_start_tls_wrong_args(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        async def main():
            with self.assertRaisesRegex(TypeError, 'SSLContext, got'):
                await self.loop.start_tls(None, None, None)

            sslctx = self._create_server_ssl_context(
                self.ONLYCERT, self.ONLYKEY)
            with self.assertRaisesRegex(TypeError, 'is not supported'):
                await self.loop.start_tls(None, None, sslctx)

        self.loop.run_until_complete(main())

    def test_ssl_handshake_timeout(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        # bpo-29970: Check that a connection is aborted if handshake is not
        # completed in timeout period, instead of remaining open indefinitely
        client_sslctx = self._create_client_ssl_context()

        # silence error logger
        messages = []
        self.loop.set_exception_handler(lambda loop, ctx: messages.append(ctx))

        server_side_aborted = False

        def server(sock):
            nonlocal server_side_aborted
            try:
                sock.recv_all(1024 * 1024)
            except ConnectionAbortedError:
                server_side_aborted = True
            finally:
                sock.close()

        async def client(addr):
            await asyncio.wait_for(
                self.loop.create_connection(
                    asyncio.Protocol,
                    *addr,
                    ssl=client_sslctx,
                    server_hostname='',
                    ssl_handshake_timeout=SSL_HANDSHAKE_TIMEOUT
                ),
                0.5
            )

        with self.tcp_server(server,
                             max_clients=1,
                             backlog=1) as srv:

            with self.assertRaises(asyncio.TimeoutError):
                self.loop.run_until_complete(client(srv.addr))

        self.assertTrue(server_side_aborted)

        # Python issue #23197: cancelling a handshake must not raise an
        # exception or log an error, even if the handshake failed
        self.assertEqual(messages, [])

    def test_ssl_handshake_connection_lost(self):
        # #246: make sure that no connection_lost() is called before
        # connection_made() is called first

        client_sslctx = self._create_client_ssl_context()

        # silence error logger
        self.loop.set_exception_handler(lambda loop, ctx: None)

        connection_made_called = False
        connection_lost_called = False

        def server(sock):
            sock.recv(1024)
            # break the connection during handshake
            sock.close()

        class ClientProto(asyncio.Protocol):
            def connection_made(self, transport):
                nonlocal connection_made_called
                connection_made_called = True

            def connection_lost(self, exc):
                nonlocal connection_lost_called
                connection_lost_called = True

        async def client(addr):
            await self.loop.create_connection(
                ClientProto,
                *addr,
                ssl=client_sslctx,
                server_hostname=''),

        with self.tcp_server(server,
                             max_clients=1,
                             backlog=1) as srv:

            with self.assertRaises(ConnectionResetError):
                self.loop.run_until_complete(client(srv.addr))

        if connection_lost_called:
            if connection_made_called:
                self.fail("unexpected call to connection_lost()")
            else:
                self.fail("unexpected call to connection_lost() without"
                          "calling connection_made()")
        elif connection_made_called:
            self.fail("unexpected call to connection_made()")

    def test_ssl_connect_accepted_socket(self):
        if hasattr(ssl, 'PROTOCOL_TLS'):
            proto = ssl.PROTOCOL_TLS
        else:
            proto = ssl.PROTOCOL_SSLv23
        server_context = ssl.SSLContext(proto)
        server_context.load_cert_chain(self.ONLYCERT, self.ONLYKEY)
        if hasattr(server_context, 'check_hostname'):
            server_context.check_hostname = False
        server_context.verify_mode = ssl.CERT_NONE

        client_context = ssl.SSLContext(proto)
        if hasattr(server_context, 'check_hostname'):
            client_context.check_hostname = False
        client_context.verify_mode = ssl.CERT_NONE

        Test_UV_TCP.test_connect_accepted_socket(
            self, server_context, client_context)

    def test_start_tls_client_corrupted_ssl(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        self.loop.set_exception_handler(lambda loop, ctx: None)

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()

        def server(sock):
            orig_sock = sock.dup()
            try:
                sock.starttls(
                    sslctx,
                    server_side=True)
                sock.sendall(b'A\n')
                sock.recv_all(1)
                orig_sock.send(b'please corrupt the SSL connection')
            except ssl.SSLError:
                pass
            finally:
                sock.close()
                orig_sock.close()

        async def client(addr):
            reader, writer = await asyncio.open_connection(
                *addr,
                ssl=client_sslctx,
                server_hostname='')

            self.assertEqual(await reader.readline(), b'A\n')
            writer.write(b'B')
            with self.assertRaises(ssl.SSLError):
                await reader.readline()
            writer.close()
            try:
                await self.wait_closed(writer)
            except ssl.SSLError:
                pass
            return 'OK'

        with self.tcp_server(server,
                             max_clients=1,
                             backlog=1) as srv:

            res = self.loop.run_until_complete(client(srv.addr))

        self.assertEqual(res, 'OK')

    def test_start_tls_client_reg_proto_1(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        HELLO_MSG = b'1' * self.PAYLOAD_SIZE

        server_context = self._create_server_ssl_context(
            self.ONLYCERT, self.ONLYKEY)
        client_context = self._create_client_ssl_context()

        def serve(sock):
            sock.settimeout(self.TIMEOUT)

            data = sock.recv_all(len(HELLO_MSG))
            self.assertEqual(len(data), len(HELLO_MSG))

            sock.starttls(server_context, server_side=True)

            sock.sendall(b'O')
            data = sock.recv_all(len(HELLO_MSG))
            self.assertEqual(len(data), len(HELLO_MSG))

            sock.unwrap()
            sock.close()

        class ClientProto(asyncio.Protocol):
            def __init__(self, on_data, on_eof):
                self.on_data = on_data
                self.on_eof = on_eof
                self.con_made_cnt = 0

            def connection_made(proto, tr):
                proto.con_made_cnt += 1
                # Ensure connection_made gets called only once.
                self.assertEqual(proto.con_made_cnt, 1)

            def data_received(self, data):
                self.on_data.set_result(data)

            def eof_received(self):
                self.on_eof.set_result(True)

        async def client(addr):
            await asyncio.sleep(0.5)

            on_data = self.loop.create_future()
            on_eof = self.loop.create_future()

            tr, proto = await self.loop.create_connection(
                lambda: ClientProto(on_data, on_eof), *addr)

            tr.write(HELLO_MSG)
            new_tr = await self.loop.start_tls(tr, proto, client_context)

            self.assertEqual(await on_data, b'O')
            new_tr.write(HELLO_MSG)
            await on_eof

            new_tr.close()

        with self.tcp_server(serve, timeout=self.TIMEOUT) as srv:
            self.loop.run_until_complete(
                asyncio.wait_for(client(srv.addr), timeout=10))

    def test_create_connection_memory_leak(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        HELLO_MSG = b'1' * self.PAYLOAD_SIZE

        server_context = self._create_server_ssl_context(
            self.ONLYCERT, self.ONLYKEY)
        client_context = self._create_client_ssl_context()

        def serve(sock):
            sock.settimeout(self.TIMEOUT)

            sock.starttls(server_context, server_side=True)

            sock.sendall(b'O')
            data = sock.recv_all(len(HELLO_MSG))
            self.assertEqual(len(data), len(HELLO_MSG))

            sock.unwrap()
            sock.close()

        class ClientProto(asyncio.Protocol):
            def __init__(self, on_data, on_eof):
                self.on_data = on_data
                self.on_eof = on_eof
                self.con_made_cnt = 0

            def connection_made(proto, tr):
                # XXX: We assume user stores the transport in protocol
                proto.tr = tr
                proto.con_made_cnt += 1
                # Ensure connection_made gets called only once.
                self.assertEqual(proto.con_made_cnt, 1)

            def data_received(self, data):
                self.on_data.set_result(data)

            def eof_received(self):
                self.on_eof.set_result(True)

        async def client(addr):
            await asyncio.sleep(0.5)

            on_data = self.loop.create_future()
            on_eof = self.loop.create_future()

            tr, proto = await self.loop.create_connection(
                lambda: ClientProto(on_data, on_eof), *addr,
                ssl=client_context)

            self.assertEqual(await on_data, b'O')
            tr.write(HELLO_MSG)
            await on_eof

            tr.close()

        with self.tcp_server(serve, timeout=self.TIMEOUT) as srv:
            self.loop.run_until_complete(
                asyncio.wait_for(client(srv.addr), timeout=10))

        # No garbage is left for SSL client from loop.create_connection, even
        # if user stores the SSLTransport in corresponding protocol instance
        client_context = weakref.ref(client_context)
        self.assertIsNone(client_context())

    def test_start_tls_client_buf_proto_1(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        HELLO_MSG = b'1' * self.PAYLOAD_SIZE

        server_context = self._create_server_ssl_context(
            self.ONLYCERT, self.ONLYKEY)
        client_context = self._create_client_ssl_context()

        client_con_made_calls = 0

        def serve(sock):
            sock.settimeout(self.TIMEOUT)

            data = sock.recv_all(len(HELLO_MSG))
            self.assertEqual(len(data), len(HELLO_MSG))

            sock.starttls(server_context, server_side=True)

            sock.sendall(b'O')
            data = sock.recv_all(len(HELLO_MSG))
            self.assertEqual(len(data), len(HELLO_MSG))

            sock.sendall(b'2')
            data = sock.recv_all(len(HELLO_MSG))
            self.assertEqual(len(data), len(HELLO_MSG))

            sock.unwrap()
            sock.close()

        class ClientProtoFirst(asyncio.BaseProtocol):
            def __init__(self, on_data):
                self.on_data = on_data
                self.buf = bytearray(1)

            def connection_made(self, tr):
                nonlocal client_con_made_calls
                client_con_made_calls += 1

            def get_buffer(self, sizehint):
                return self.buf

            def buffer_updated(self, nsize):
                assert nsize == 1
                self.on_data.set_result(bytes(self.buf[:nsize]))

            def eof_received(self):
                pass

        class ClientProtoSecond(asyncio.Protocol):
            def __init__(self, on_data, on_eof):
                self.on_data = on_data
                self.on_eof = on_eof
                self.con_made_cnt = 0

            def connection_made(self, tr):
                nonlocal client_con_made_calls
                client_con_made_calls += 1

            def data_received(self, data):
                self.on_data.set_result(data)

            def eof_received(self):
                self.on_eof.set_result(True)

        async def client(addr):
            await asyncio.sleep(0.5)

            on_data1 = self.loop.create_future()
            on_data2 = self.loop.create_future()
            on_eof = self.loop.create_future()

            tr, proto = await self.loop.create_connection(
                lambda: ClientProtoFirst(on_data1), *addr)

            tr.write(HELLO_MSG)
            new_tr = await self.loop.start_tls(tr, proto, client_context)

            self.assertEqual(await on_data1, b'O')
            new_tr.write(HELLO_MSG)

            new_tr.set_protocol(ClientProtoSecond(on_data2, on_eof))
            self.assertEqual(await on_data2, b'2')
            new_tr.write(HELLO_MSG)
            await on_eof

            new_tr.close()

            # connection_made() should be called only once -- when
            # we establish connection for the first time. Start TLS
            # doesn't call connection_made() on application protocols.
            self.assertEqual(client_con_made_calls, 1)

        with self.tcp_server(serve, timeout=self.TIMEOUT) as srv:
            self.loop.run_until_complete(
                asyncio.wait_for(client(srv.addr),
                                 timeout=self.TIMEOUT))

    def test_start_tls_slow_client_cancel(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        HELLO_MSG = b'1' * self.PAYLOAD_SIZE

        client_context = self._create_client_ssl_context()
        server_waits_on_handshake = self.loop.create_future()

        def serve(sock):
            sock.settimeout(self.TIMEOUT)

            data = sock.recv_all(len(HELLO_MSG))
            self.assertEqual(len(data), len(HELLO_MSG))

            try:
                self.loop.call_soon_threadsafe(
                    server_waits_on_handshake.set_result, None)
                data = sock.recv_all(1024 * 1024)
            except ConnectionAbortedError:
                pass
            finally:
                sock.close()

        class ClientProto(asyncio.Protocol):
            def __init__(self, on_data, on_eof):
                self.on_data = on_data
                self.on_eof = on_eof
                self.con_made_cnt = 0

            def connection_made(proto, tr):
                proto.con_made_cnt += 1
                # Ensure connection_made gets called only once.
                self.assertEqual(proto.con_made_cnt, 1)

            def data_received(self, data):
                self.on_data.set_result(data)

            def eof_received(self):
                self.on_eof.set_result(True)

        async def client(addr):
            await asyncio.sleep(0.5)

            on_data = self.loop.create_future()
            on_eof = self.loop.create_future()

            tr, proto = await self.loop.create_connection(
                lambda: ClientProto(on_data, on_eof), *addr)

            tr.write(HELLO_MSG)

            await server_waits_on_handshake

            with self.assertRaises(asyncio.TimeoutError):
                await asyncio.wait_for(
                    self.loop.start_tls(tr, proto, client_context),
                    0.5)

        with self.tcp_server(serve, timeout=self.TIMEOUT) as srv:
            self.loop.run_until_complete(
                asyncio.wait_for(client(srv.addr), timeout=10))

    def test_start_tls_server_1(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        HELLO_MSG = b'1' * self.PAYLOAD_SIZE

        server_context = self._create_server_ssl_context(
            self.ONLYCERT, self.ONLYKEY)
        client_context = self._create_client_ssl_context()

        def client(sock, addr):
            sock.settimeout(self.TIMEOUT)

            sock.connect(addr)
            data = sock.recv_all(len(HELLO_MSG))
            self.assertEqual(len(data), len(HELLO_MSG))

            sock.starttls(client_context)
            sock.sendall(HELLO_MSG)

            sock.unwrap()
            sock.close()

        class ServerProto(asyncio.Protocol):
            def __init__(self, on_con, on_eof, on_con_lost):
                self.on_con = on_con
                self.on_eof = on_eof
                self.on_con_lost = on_con_lost
                self.data = b''

            def connection_made(self, tr):
                self.on_con.set_result(tr)

            def data_received(self, data):
                self.data += data

            def eof_received(self):
                self.on_eof.set_result(1)

            def connection_lost(self, exc):
                if exc is None:
                    self.on_con_lost.set_result(None)
                else:
                    self.on_con_lost.set_exception(exc)

        async def main(proto, on_con, on_eof, on_con_lost):
            tr = await on_con
            tr.write(HELLO_MSG)

            self.assertEqual(proto.data, b'')

            new_tr = await self.loop.start_tls(
                tr, proto, server_context,
                server_side=True,
                ssl_handshake_timeout=self.TIMEOUT)

            await on_eof
            await on_con_lost
            self.assertEqual(proto.data, HELLO_MSG)
            new_tr.close()

        async def run_main():
            on_con = self.loop.create_future()
            on_eof = self.loop.create_future()
            on_con_lost = self.loop.create_future()
            proto = ServerProto(on_con, on_eof, on_con_lost)

            server = await self.loop.create_server(
                lambda: proto, '127.0.0.1', 0)
            addr = server.sockets[0].getsockname()

            with self.tcp_client(lambda sock: client(sock, addr),
                                 timeout=self.TIMEOUT):
                await asyncio.wait_for(
                    main(proto, on_con, on_eof, on_con_lost),
                    timeout=self.TIMEOUT)

            server.close()
            await server.wait_closed()

        self.loop.run_until_complete(run_main())

    def test_create_server_ssl_over_ssl(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest('asyncio does not support SSL over SSL')

        CNT = 0           # number of clients that were successful
        TOTAL_CNT = 25    # total number of clients that test will create
        TIMEOUT = 20.0    # timeout for this test

        A_DATA = b'A' * 1024 * 1024
        B_DATA = b'B' * 1024 * 1024

        sslctx_1 = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx_1 = self._create_client_ssl_context()
        sslctx_2 = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx_2 = self._create_client_ssl_context()

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

        class ServerProtocol(asyncio.StreamReaderProtocol):
            def connection_made(self, transport):
                super_ = super()
                transport.pause_reading()
                fut = self._loop.create_task(self._loop.start_tls(
                    transport, self, sslctx_2, server_side=True))

                def cb(_):
                    try:
                        tr = fut.result()
                    except Exception as ex:
                        super_.connection_lost(ex)
                    else:
                        super_.connection_made(tr)
                fut.add_done_callback(cb)

        def server_protocol_factory():
            reader = asyncio.StreamReader()
            protocol = ServerProtocol(reader, handle_client)
            return protocol

        async def test_client(addr):
            fut = asyncio.Future()

            def prog(sock):
                try:
                    sock.connect(addr)
                    sock.starttls(client_sslctx_1)

                    # because wrap_socket() doesn't work correctly on
                    # SSLSocket, we have to do the 2nd level SSL manually
                    incoming = ssl.MemoryBIO()
                    outgoing = ssl.MemoryBIO()
                    sslobj = client_sslctx_2.wrap_bio(incoming, outgoing)

                    def do(func, *args):
                        while True:
                            try:
                                rv = func(*args)
                                break
                            except ssl.SSLWantReadError:
                                if outgoing.pending:
                                    sock.send(outgoing.read())
                                incoming.write(sock.recv(65536))
                        if outgoing.pending:
                            sock.send(outgoing.read())
                        return rv

                    do(sslobj.do_handshake)

                    do(sslobj.write, A_DATA)
                    data = do(sslobj.read, 2)
                    self.assertEqual(data, b'OK')

                    do(sslobj.write, B_DATA)
                    data = b''
                    while True:
                        chunk = do(sslobj.read, 4)
                        if not chunk:
                            break
                        data += chunk
                    self.assertEqual(data, b'SPAM')

                    do(sslobj.unwrap)
                    sock.close()

                except Exception as ex:
                    self.loop.call_soon_threadsafe(fut.set_exception, ex)
                    sock.close()
                else:
                    self.loop.call_soon_threadsafe(fut.set_result, None)

            client = self.tcp_client(prog)
            client.start()
            clients.append(client)

            await fut

        async def start_server():
            extras = dict(ssl_handshake_timeout=SSL_HANDSHAKE_TIMEOUT)

            srv = await self.loop.create_server(
                server_protocol_factory,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                ssl=sslctx_1,
                **extras)

            try:
                srv_socks = srv.sockets
                self.assertTrue(srv_socks)

                addr = srv_socks[0].getsockname()

                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(test_client(addr))

                await asyncio.wait_for(asyncio.gather(*tasks), TIMEOUT)

            finally:
                self.loop.call_soon(srv.close)
                await srv.wait_closed()

        with self._silence_eof_received_warning():
            self.loop.run_until_complete(start_server())

        self.assertEqual(CNT, TOTAL_CNT)

        for client in clients:
            client.stop()

    def test_renegotiation(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest('asyncio does not support renegotiation')

        CNT = 0
        TOTAL_CNT = 25

        A_DATA = b'A' * 1024 * 1024
        B_DATA = b'B' * 1024 * 1024

        sslctx = openssl_ssl.Context(openssl_ssl.TLSv1_2_METHOD)
        if hasattr(openssl_ssl, 'OP_NO_SSLV2'):
            sslctx.set_options(openssl_ssl.OP_NO_SSLV2)
        sslctx.use_privatekey_file(self.ONLYKEY)
        sslctx.use_certificate_chain_file(self.ONLYCERT)
        client_sslctx = self._create_client_ssl_context()
        if hasattr(ssl, 'OP_NO_TLSv1_3'):
            client_sslctx.options |= ssl.OP_NO_TLSv1_3

        def server(sock):
            conn = openssl_ssl.Connection(sslctx, sock)
            conn.set_accept_state()

            data = b''
            while len(data) < len(A_DATA):
                try:
                    chunk = conn.recv(len(A_DATA) - len(data))
                    if not chunk:
                        break
                    data += chunk
                except openssl_ssl.WantReadError:
                    pass
            self.assertEqual(data, A_DATA)
            conn.renegotiate()
            if conn.renegotiate_pending():
                conn.send(b'OK')
            else:
                conn.send(b'ER')

            data = b''
            while len(data) < len(B_DATA):
                try:
                    chunk = conn.recv(len(B_DATA) - len(data))
                    if not chunk:
                        break
                    data += chunk
                except openssl_ssl.WantReadError:
                    pass
            self.assertEqual(data, B_DATA)
            if conn.renegotiate_pending():
                conn.send(b'ERRO')
            else:
                conn.send(b'SPAM')

            conn.shutdown()

        async def client(addr):
            extras = dict(ssl_handshake_timeout=SSL_HANDSHAKE_TIMEOUT)

            reader, writer = await asyncio.open_connection(
                *addr,
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

        async def client_sock(addr):
            sock = socket.socket()
            sock.connect(addr)
            reader, writer = await asyncio.open_connection(
                sock=sock,
                ssl=client_sslctx,
                server_hostname='')

            writer.write(A_DATA)
            self.assertEqual(await reader.readexactly(2), b'OK')

            writer.write(B_DATA)
            self.assertEqual(await reader.readexactly(4), b'SPAM')

            nonlocal CNT
            CNT += 1

            writer.close()
            await self.wait_closed(writer)
            sock.close()

        def run(coro):
            nonlocal CNT
            CNT = 0

            with self.tcp_server(server,
                                 max_clients=TOTAL_CNT,
                                 backlog=TOTAL_CNT) as srv:
                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(coro(srv.addr))

                self.loop.run_until_complete(
                    asyncio.gather(*tasks))

            self.assertEqual(CNT, TOTAL_CNT)

        with self._silence_eof_received_warning():
            run(client)

        with self._silence_eof_received_warning():
            run(client_sock)

    def test_shutdown_timeout(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        CNT = 0           # number of clients that were successful
        TOTAL_CNT = 25    # total number of clients that test will create
        TIMEOUT = 10.0    # timeout for this test

        A_DATA = b'A' * 1024 * 1024

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()

        clients = []

        async def handle_client(reader, writer):
            nonlocal CNT

            data = await reader.readexactly(len(A_DATA))
            self.assertEqual(data, A_DATA)
            writer.write(b'OK')
            await writer.drain()
            writer.close()
            with self.assertRaisesRegex(asyncio.TimeoutError,
                                        'SSL shutdown timed out'):
                await reader.read()
            CNT += 1

        async def test_client(addr):
            fut = asyncio.Future()

            def prog(sock):
                try:
                    sock.starttls(client_sslctx)
                    sock.connect(addr)
                    sock.send(A_DATA)

                    data = sock.recv_all(2)
                    self.assertEqual(data, b'OK')

                    data = sock.recv(1024)
                    self.assertEqual(data, b'')

                    fd = sock.detach()
                    try:
                        select.select([fd], [], [], 3)
                    finally:
                        os.close(fd)

                except Exception as ex:
                    self.loop.call_soon_threadsafe(fut.set_exception, ex)
                else:
                    self.loop.call_soon_threadsafe(fut.set_result, None)

            client = self.tcp_client(prog)
            client.start()
            clients.append(client)

            await fut

        async def start_server():
            extras = {'ssl_handshake_timeout': SSL_HANDSHAKE_TIMEOUT}
            if self.implementation != 'asyncio':  # or self.PY38
                extras['ssl_shutdown_timeout'] = 0.5

            srv = await asyncio.start_server(
                handle_client,
                '127.0.0.1', 0,
                family=socket.AF_INET,
                ssl=sslctx,
                **extras)

            try:
                srv_socks = srv.sockets
                self.assertTrue(srv_socks)

                addr = srv_socks[0].getsockname()

                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(test_client(addr))

                await asyncio.wait_for(
                    asyncio.gather(*tasks),
                    TIMEOUT)

            finally:
                self.loop.call_soon(srv.close)
                await srv.wait_closed()

        with self._silence_eof_received_warning():
            self.loop.run_until_complete(start_server())

        self.assertEqual(CNT, TOTAL_CNT)

        for client in clients:
            client.stop()

    def test_shutdown_cleanly(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        CNT = 0
        TOTAL_CNT = 25

        A_DATA = b'A' * 1024 * 1024

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()

        def server(sock):
            sock.starttls(
                sslctx,
                server_side=True)

            data = sock.recv_all(len(A_DATA))
            self.assertEqual(data, A_DATA)
            sock.send(b'OK')

            sock.unwrap()

            sock.close()

        async def client(addr):
            extras = dict(ssl_handshake_timeout=SSL_HANDSHAKE_TIMEOUT)

            reader, writer = await asyncio.open_connection(
                *addr,
                ssl=client_sslctx,
                server_hostname='',
                **extras)

            writer.write(A_DATA)
            self.assertEqual(await reader.readexactly(2), b'OK')

            self.assertEqual(await reader.read(), b'')

            nonlocal CNT
            CNT += 1

            writer.close()
            await self.wait_closed(writer)

        def run(coro):
            nonlocal CNT
            CNT = 0

            with self.tcp_server(server,
                                 max_clients=TOTAL_CNT,
                                 backlog=TOTAL_CNT) as srv:
                tasks = []
                for _ in range(TOTAL_CNT):
                    tasks.append(coro(srv.addr))

                self.loop.run_until_complete(
                    asyncio.gather(*tasks))

            self.assertEqual(CNT, TOTAL_CNT)

        with self._silence_eof_received_warning():
            run(client)

    def test_write_to_closed_transport(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()
        future = None

        def server(sock):
            sock.starttls(sslctx, server_side=True)
            sock.shutdown(socket.SHUT_RDWR)
            sock.close()

        def unwrap_server(sock):
            sock.starttls(sslctx, server_side=True)
            while True:
                try:
                    sock.unwrap()
                    break
                except ssl.SSLError as ex:
                    # Since OpenSSL 1.1.1, it raises "application data after
                    # close notify"
                    # Python < 3.8:
                    if ex.reason == 'KRB5_S_INIT':
                        break
                    # Python >= 3.8:
                    if ex.reason == 'APPLICATION_DATA_AFTER_CLOSE_NOTIFY':
                        break
                    raise ex
                except OSError as ex:
                    # OpenSSL < 1.1.1
                    if ex.errno != 0:
                        raise
            sock.close()

        async def client(addr):
            nonlocal future
            future = self.loop.create_future()

            reader, writer = await asyncio.open_connection(
                *addr,
                ssl=client_sslctx,
                server_hostname='')
            writer.write(b'I AM WRITING NOWHERE1' * 100)

            try:
                data = await reader.read()
                self.assertEqual(data, b'')
            except (ConnectionResetError, BrokenPipeError):
                pass

            for i in range(25):
                writer.write(b'I AM WRITING NOWHERE2' * 100)

            self.assertEqual(
                writer.transport.get_write_buffer_size(), 0)

            await future

            writer.close()
            await self.wait_closed(writer)

        def run(meth):
            def wrapper(sock):
                try:
                    meth(sock)
                except Exception as ex:
                    self.loop.call_soon_threadsafe(future.set_exception, ex)
                else:
                    self.loop.call_soon_threadsafe(future.set_result, None)
            return wrapper

        with self._silence_eof_received_warning():
            with self.tcp_server(run(server)) as srv:
                self.loop.run_until_complete(client(srv.addr))

            with self.tcp_server(run(unwrap_server)) as srv:
                self.loop.run_until_complete(client(srv.addr))

    def test_flush_before_shutdown(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        CHUNK = 1024 * 128
        SIZE = 32

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        sslctx_openssl = openssl_ssl.Context(openssl_ssl.TLSv1_2_METHOD)
        if hasattr(openssl_ssl, 'OP_NO_SSLV2'):
            sslctx_openssl.set_options(openssl_ssl.OP_NO_SSLV2)
        sslctx_openssl.use_privatekey_file(self.ONLYKEY)
        sslctx_openssl.use_certificate_chain_file(self.ONLYCERT)
        client_sslctx = self._create_client_ssl_context()
        if hasattr(ssl, 'OP_NO_TLSv1_3'):
            client_sslctx.options |= ssl.OP_NO_TLSv1_3

        future = None

        def server(sock):
            sock.starttls(sslctx, server_side=True)
            self.assertEqual(sock.recv_all(4), b'ping')
            sock.send(b'pong')
            time.sleep(0.5)  # hopefully stuck the TCP buffer
            data = sock.recv_all(CHUNK * SIZE)
            self.assertEqual(len(data), CHUNK * SIZE)
            sock.close()

        def run(meth):
            def wrapper(sock):
                try:
                    meth(sock)
                except Exception as ex:
                    self.loop.call_soon_threadsafe(future.set_exception, ex)
                else:
                    self.loop.call_soon_threadsafe(future.set_result, None)
            return wrapper

        async def client(addr):
            nonlocal future
            future = self.loop.create_future()
            reader, writer = await asyncio.open_connection(
                *addr,
                ssl=client_sslctx,
                server_hostname='')
            sslprotocol = writer.get_extra_info('uvloop.sslproto')
            writer.write(b'ping')
            data = await reader.readexactly(4)
            self.assertEqual(data, b'pong')

            sslprotocol.pause_writing()
            for _ in range(SIZE):
                writer.write(b'x' * CHUNK)

            writer.close()
            sslprotocol.resume_writing()

            await self.wait_closed(writer)
            try:
                data = await reader.read()
                self.assertEqual(data, b'')
            except ConnectionResetError:
                pass
            await future

        with self.tcp_server(run(server)) as srv:
            self.loop.run_until_complete(client(srv.addr))

    def test_remote_shutdown_receives_trailing_data(self):
        CHUNK = 1024 * 16
        SIZE = 8
        count = 0

        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()
        future = None
        filled = threading.Lock()
        eof_received = threading.Lock()

        def server(sock):
            incoming = ssl.MemoryBIO()
            outgoing = ssl.MemoryBIO()
            sslobj = sslctx.wrap_bio(incoming, outgoing, server_side=True)

            while True:
                try:
                    sslobj.do_handshake()
                except ssl.SSLWantReadError:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    incoming.write(sock.recv(16384))
                else:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    break

            while True:
                try:
                    data = sslobj.read(4)
                except ssl.SSLWantReadError:
                    incoming.write(sock.recv(16384))
                else:
                    break

            self.assertEqual(data, b'ping')
            sslobj.write(b'pong')
            sock.send(outgoing.read())

            data_len = 0

            with filled:
                # trigger peer's resume_writing()
                incoming.write(sock.recv(65536 * 4))
                while True:
                    try:
                        chunk = len(sslobj.read(16384))
                        data_len += chunk
                    except ssl.SSLWantReadError:
                        break

                # send close_notify but don't wait for response
                with self.assertRaises(ssl.SSLWantReadError):
                    sslobj.unwrap()
                sock.send(outgoing.read())

            with eof_received:
                # should receive all data
                while True:
                    try:
                        chunk = len(sslobj.read(16384))
                        data_len += chunk
                    except ssl.SSLWantReadError:
                        incoming.write(sock.recv(16384))
                        if not incoming.pending:
                            # EOF received
                            break
                    except ssl.SSLZeroReturnError:
                        break

            self.assertEqual(data_len, CHUNK * count)

            if self.implementation == 'uvloop':
                # Verify that close_notify is received. asyncio is currently
                # not guaranteed to send close_notify before dropping off
                sslobj.unwrap()

            sock.close()

        async def client(addr):
            nonlocal future, count
            future = self.loop.create_future()

            with eof_received:
                with filled:
                    reader, writer = await asyncio.open_connection(
                        *addr,
                        ssl=client_sslctx,
                        server_hostname='')
                    writer.write(b'ping')
                    data = await reader.readexactly(4)
                    self.assertEqual(data, b'pong')

                    count = 0
                    try:
                        while True:
                            writer.write(b'x' * CHUNK)
                            count += 1
                            await asyncio.wait_for(
                                asyncio.ensure_future(writer.drain()), 0.5)
                    except asyncio.TimeoutError:
                        # fill write backlog in a hacky way for uvloop
                        if self.implementation == 'uvloop':
                            for _ in range(SIZE):
                                writer.transport._test__append_write_backlog(
                                    b'x' * CHUNK)
                                count += 1

                data = await reader.read()
                self.assertEqual(data, b'')

            await future

            writer.close()
            await self.wait_closed(writer)

        def run(meth):
            def wrapper(sock):
                try:
                    meth(sock)
                except Exception as ex:
                    self.loop.call_soon_threadsafe(future.set_exception, ex)
                else:
                    self.loop.call_soon_threadsafe(future.set_result, None)
            return wrapper

        with self.tcp_server(run(server)) as srv:
            self.loop.run_until_complete(client(srv.addr))

    def test_connect_timeout_warning(self):
        s = socket.socket(socket.AF_INET)
        s.bind(('127.0.0.1', 0))
        addr = s.getsockname()

        async def test():
            try:
                await asyncio.wait_for(
                    self.loop.create_connection(asyncio.Protocol,
                                                *addr, ssl=True),
                    0.1)
            except (ConnectionRefusedError, asyncio.TimeoutError):
                pass
            else:
                self.fail('TimeoutError is not raised')

        with s:
            try:
                with self.assertWarns(ResourceWarning) as cm:
                    self.loop.run_until_complete(test())
                    gc.collect()
                    gc.collect()
                    gc.collect()
            except AssertionError as e:
                self.assertEqual(str(e), 'ResourceWarning not triggered')
            else:
                self.fail('Unexpected ResourceWarning: {}'.format(cm.warning))

    def test_handshake_timeout_handler_leak(self):
        if self.implementation == 'asyncio':
            # Okay this turns out to be an issue for asyncio.sslproto too
            raise unittest.SkipTest()

        s = socket.socket(socket.AF_INET)
        s.bind(('127.0.0.1', 0))
        s.listen(1)
        addr = s.getsockname()

        async def test(ctx):
            try:
                await asyncio.wait_for(
                    self.loop.create_connection(asyncio.Protocol, *addr,
                                                ssl=ctx),
                    0.1)
            except (ConnectionRefusedError, asyncio.TimeoutError):
                pass
            else:
                self.fail('TimeoutError is not raised')

        with s:
            ctx = ssl.create_default_context()
            self.loop.run_until_complete(test(ctx))
            ctx = weakref.ref(ctx)

        # SSLProtocol should be DECREF to 0
        self.assertIsNone(ctx())

    def test_shutdown_timeout_handler_leak(self):
        loop = self.loop

        def server(sock):
            sslctx = self._create_server_ssl_context(self.ONLYCERT,
                                                     self.ONLYKEY)
            sock = sslctx.wrap_socket(sock, server_side=True)
            sock.recv(32)
            sock.close()

        class Protocol(asyncio.Protocol):
            def __init__(self):
                self.fut = asyncio.Future(loop=loop)

            def connection_lost(self, exc):
                self.fut.set_result(None)

        async def client(addr, ctx):
            tr, pr = await loop.create_connection(Protocol, *addr, ssl=ctx)
            tr.close()
            await pr.fut

        with self.tcp_server(server) as srv:
            ctx = self._create_client_ssl_context()
            loop.run_until_complete(client(srv.addr, ctx))
            ctx = weakref.ref(ctx)

        if self.implementation == 'asyncio':
            # asyncio has no shutdown timeout, but it ends up with a circular
            # reference loop - not ideal (introduces gc glitches), but at least
            # not leaking
            gc.collect()
            gc.collect()
            gc.collect()

        # SSLProtocol should be DECREF to 0
        self.assertIsNone(ctx())

    def test_shutdown_timeout_handler_not_set(self):
        loop = self.loop
        eof = asyncio.Event()
        extra = None

        def server(sock):
            sslctx = self._create_server_ssl_context(self.ONLYCERT,
                                                     self.ONLYKEY)
            sock = sslctx.wrap_socket(sock, server_side=True)
            sock.send(b'hello')
            assert sock.recv(1024) == b'world'
            sock.send(b'extra bytes')
            # sending EOF here
            sock.shutdown(socket.SHUT_WR)
            loop.call_soon_threadsafe(eof.set)
            # make sure we have enough time to reproduce the issue
            self.assertEqual(sock.recv(1024), b'')
            sock.close()

        class Protocol(asyncio.Protocol):
            def __init__(self):
                self.fut = asyncio.Future(loop=loop)
                self.transport = None

            def connection_made(self, transport):
                self.transport = transport

            def data_received(self, data):
                if data == b'hello':
                    self.transport.write(b'world')
                    # pause reading would make incoming data stay in the sslobj
                    self.transport.pause_reading()
                else:
                    nonlocal extra
                    extra = data

            def connection_lost(self, exc):
                if exc is None:
                    self.fut.set_result(None)
                else:
                    self.fut.set_exception(exc)

        async def client(addr):
            ctx = self._create_client_ssl_context()
            tr, pr = await loop.create_connection(Protocol, *addr, ssl=ctx)
            await eof.wait()
            tr.resume_reading()
            await pr.fut
            tr.close()
            if self.implementation != 'asyncio':
                # extra data received after transport.close() should be
                # ignored - this is likely a bug in asyncio
                self.assertIsNone(extra)

        with self.tcp_server(server) as srv:
            loop.run_until_complete(client(srv.addr))

    def test_shutdown_while_pause_reading(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest()

        loop = self.loop
        conn_made = loop.create_future()
        eof_recvd = loop.create_future()
        conn_lost = loop.create_future()
        data_recv = False

        def server(sock):
            sslctx = self._create_server_ssl_context(self.ONLYCERT,
                                                     self.ONLYKEY)
            incoming = ssl.MemoryBIO()
            outgoing = ssl.MemoryBIO()
            sslobj = sslctx.wrap_bio(incoming, outgoing, server_side=True)

            while True:
                try:
                    sslobj.do_handshake()
                    sslobj.write(b'trailing data')
                    break
                except ssl.SSLWantReadError:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    incoming.write(sock.recv(16384))
            if outgoing.pending:
                sock.send(outgoing.read())

            while True:
                try:
                    self.assertEqual(sslobj.read(), b'')  # close_notify
                    break
                except ssl.SSLWantReadError:
                    incoming.write(sock.recv(16384))

            while True:
                try:
                    sslobj.unwrap()
                except ssl.SSLWantReadError:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    incoming.write(sock.recv(16384))
                else:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    break

            self.assertEqual(sock.recv(16384), b'')  # socket closed

        class Protocol(asyncio.Protocol):
            def connection_made(self, transport):
                conn_made.set_result(None)

            def data_received(self, data):
                nonlocal data_recv
                data_recv = True

            def eof_received(self):
                eof_recvd.set_result(None)

            def connection_lost(self, exc):
                if exc is None:
                    conn_lost.set_result(None)
                else:
                    conn_lost.set_exception(exc)

        async def client(addr):
            ctx = self._create_client_ssl_context()
            tr, _ = await loop.create_connection(Protocol, *addr, ssl=ctx)
            await conn_made
            self.assertFalse(data_recv)

            tr.pause_reading()
            tr.close()

            await asyncio.wait_for(eof_recvd, 10)
            await asyncio.wait_for(conn_lost, 10)

        with self.tcp_server(server) as srv:
            loop.run_until_complete(client(srv.addr))

    def test_bpo_39951_discard_trailing_data(self):
        sslctx = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
        client_sslctx = self._create_client_ssl_context()
        future = None
        close_notify = threading.Lock()

        def server(sock):
            incoming = ssl.MemoryBIO()
            outgoing = ssl.MemoryBIO()
            sslobj = sslctx.wrap_bio(incoming, outgoing, server_side=True)

            while True:
                try:
                    sslobj.do_handshake()
                except ssl.SSLWantReadError:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    incoming.write(sock.recv(16384))
                else:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    break

            while True:
                try:
                    data = sslobj.read(4)
                except ssl.SSLWantReadError:
                    incoming.write(sock.recv(16384))
                else:
                    break

            self.assertEqual(data, b'ping')
            sslobj.write(b'pong')
            sock.send(outgoing.read())

            with close_notify:
                sslobj.write(b'trailing')
                sock.send(outgoing.read())
                time.sleep(0.5)  # allow time for the client to receive

            incoming.write(sock.recv(16384))
            sslobj.unwrap()
            sock.send(outgoing.read())
            sock.close()

        async def client(addr):
            nonlocal future
            future = self.loop.create_future()

            with close_notify:
                reader, writer = await asyncio.open_connection(
                    *addr,
                    ssl=client_sslctx,
                    server_hostname='')
                writer.write(b'ping')
                data = await reader.readexactly(4)
                self.assertEqual(data, b'pong')

                writer.close()

            try:
                await self.wait_closed(writer)
            except ssl.SSLError as e:
                if self.implementation == 'asyncio' and \
                        'application data after close notify' in str(e):
                    raise unittest.SkipTest('bpo-39951')
                raise
            await future

        def run(meth):
            def wrapper(sock):
                try:
                    meth(sock)
                except Exception as ex:
                    self.loop.call_soon_threadsafe(future.set_exception, ex)
                else:
                    self.loop.call_soon_threadsafe(future.set_result, None)
            return wrapper

        with self.tcp_server(run(server)) as srv:
            self.loop.run_until_complete(client(srv.addr))


class Test_UV_TCPSSL(_TestSSL, tb.UVTestCase):
    pass


class Test_AIO_TCPSSL(_TestSSL, tb.AIOTestCase):
    pass
