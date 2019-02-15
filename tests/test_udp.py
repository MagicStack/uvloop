import asyncio
import os
import socket
import sys
import tempfile
import unittest
import uuid

from uvloop import _testbase as tb


class MyDatagramProto(asyncio.DatagramProtocol):
    done = None

    def __init__(self, loop=None):
        self.state = 'INITIAL'
        self.nbytes = 0
        if loop is not None:
            self.done = asyncio.Future(loop=loop)

    def connection_made(self, transport):
        self.transport = transport
        assert self.state == 'INITIAL', self.state
        self.state = 'INITIALIZED'

    def datagram_received(self, data, addr):
        assert self.state == 'INITIALIZED', self.state
        self.nbytes += len(data)

    def error_received(self, exc):
        assert self.state == 'INITIALIZED', self.state
        raise exc

    def connection_lost(self, exc):
        assert self.state == 'INITIALIZED', self.state
        self.state = 'CLOSED'
        if self.done:
            self.done.set_result(None)


class _TestUDP:

    def _test_create_datagram_endpoint_addrs(self, family, lc_addr):
        class TestMyDatagramProto(MyDatagramProto):
            def __init__(inner_self):
                super().__init__(loop=self.loop)

            def datagram_received(self, data, addr):
                super().datagram_received(data, addr)
                self.transport.sendto(b'resp:' + data, addr)

        coro = self.loop.create_datagram_endpoint(
            TestMyDatagramProto,
            local_addr=lc_addr,
            family=family)

        s_transport, server = self.loop.run_until_complete(coro)

        host, port, *_ = s_transport.get_extra_info('sockname')

        self.assertIsInstance(server, TestMyDatagramProto)
        self.assertEqual('INITIALIZED', server.state)
        self.assertIs(server.transport, s_transport)

        extra = {}
        if hasattr(socket, 'SO_REUSEPORT') and \
                sys.version_info[:3] >= (3, 5, 1):
            extra['reuse_port'] = True

        coro = self.loop.create_datagram_endpoint(
            lambda: MyDatagramProto(loop=self.loop),
            family=family,
            remote_addr=(host, port),
            **extra)
        transport, client = self.loop.run_until_complete(coro)

        self.assertIsInstance(client, MyDatagramProto)
        self.assertEqual('INITIALIZED', client.state)
        self.assertIs(client.transport, transport)

        transport.sendto(b'xxx')
        tb.run_until(self.loop, lambda: server.nbytes)
        self.assertEqual(3, server.nbytes)
        tb.run_until(self.loop, lambda: client.nbytes)

        # received
        self.assertEqual(8, client.nbytes)

        # extra info is available
        self.assertIsNotNone(transport.get_extra_info('sockname'))

        # close connection
        transport.close()
        self.loop.run_until_complete(client.done)
        self.assertEqual('CLOSED', client.state)
        server.transport.close()
        self.loop.run_until_complete(server.done)

    def test_create_datagram_endpoint_addrs_ipv4(self):
        self._test_create_datagram_endpoint_addrs(
            socket.AF_INET, ('127.0.0.1', 0))

    @unittest.skipUnless(tb.has_IPv6, 'no IPv6')
    def test_create_datagram_endpoint_addrs_ipv6(self):
        self._test_create_datagram_endpoint_addrs(
            socket.AF_INET6, ('::1', 0))

    def test_create_datagram_endpoint_ipv6_family(self):
        class TestMyDatagramProto(MyDatagramProto):
            def __init__(inner_self):
                super().__init__(loop=self.loop)

            def datagram_received(self, data, addr):
                super().datagram_received(data, addr)
                self.transport.sendto(b'resp:' + data, addr)

        coro = self.loop.create_datagram_endpoint(
            TestMyDatagramProto, local_addr=None, family=socket.AF_INET6)
        s_transport = None
        try:
            s_transport, server = self.loop.run_until_complete(coro)
        finally:
            if s_transport:
                s_transport.close()
                # let it close
                self.loop.run_until_complete(
                    asyncio.sleep(0.1, loop=self.loop))

    def test_create_datagram_endpoint_sock(self):
        sock = None
        local_address = ('127.0.0.1', 0)
        infos = self.loop.run_until_complete(
            self.loop.getaddrinfo(
                *local_address, type=socket.SOCK_DGRAM))
        for family, type, proto, cname, address in infos:
            try:
                sock = socket.socket(family=family, type=type, proto=proto)
                sock.setblocking(False)
                sock.bind(address)
            except Exception:
                pass
            else:
                break
        else:
            assert False, 'Can not create socket.'

        with sock:
            try:
                f = self.loop.create_datagram_endpoint(
                    lambda: MyDatagramProto(loop=self.loop), sock=sock)
            except TypeError as ex:
                # asyncio in 3.5.0 doesn't have the 'sock' argument
                if 'got an unexpected keyword argument' not in ex.args[0]:
                    raise
            else:
                tr, pr = self.loop.run_until_complete(f)
                self.assertIsInstance(pr, MyDatagramProto)
                tr.close()
                self.loop.run_until_complete(pr.done)

    @unittest.skipIf(sys.version_info < (3, 5, 1),
                     "asyncio in 3.5.0 doesn't have the 'sock' argument")
    def test_create_datagram_endpoint_sock_unix_domain(self):
        tmp_file = os.path.join(tempfile.gettempdir(), str(uuid.uuid4()))
        sock = socket.socket(socket.AF_UNIX, type=socket.SOCK_DGRAM)
        sock.bind(tmp_file)

        with sock:
            f = self.loop.create_datagram_endpoint(
                lambda: MyDatagramProto(loop=self.loop), sock=sock)
            tr, pr = self.loop.run_until_complete(f)
            self.assertIsInstance(pr, MyDatagramProto)
            tr.sendto(b'HELLO', tmp_file)
            tr.close()
            self.loop.run_until_complete(pr.done)


class Test_UV_UDP(_TestUDP, tb.UVTestCase):

    def test_create_datagram_endpoint_wrong_sock(self):
        sock = socket.socket(socket.AF_INET)
        with sock:
            coro = self.loop.create_datagram_endpoint(lambda: None, sock=sock)
            with self.assertRaisesRegex(ValueError,
                                        'A UDP Socket was expected'):
                self.loop.run_until_complete(coro)

    def test_udp_sendto_dns(self):
        coro = self.loop.create_datagram_endpoint(
            asyncio.DatagramProtocol,
            local_addr=('127.0.0.1', 0),
            family=socket.AF_INET)

        s_transport, server = self.loop.run_until_complete(coro)

        with self.assertRaisesRegex(ValueError, 'DNS lookup'):
            s_transport.sendto(b'aaaa', ('example.com', 80))

        with self.assertRaisesRegex(ValueError, 'socket family mismatch'):
            s_transport.sendto(b'aaaa', ('::1', 80))

        s_transport.close()
        self.loop.run_until_complete(asyncio.sleep(0.01, loop=self.loop))

    def test_send_after_close(self):
        coro = self.loop.create_datagram_endpoint(
            asyncio.DatagramProtocol,
            local_addr=('127.0.0.1', 0),
            family=socket.AF_INET)

        s_transport, _ = self.loop.run_until_complete(coro)

        s_transport.close()
        s_transport.sendto(b'aaaa', ('127.0.0.1', 80))
        self.loop.run_until_complete(asyncio.sleep(0.01, loop=self.loop))
        s_transport.sendto(b'aaaa', ('127.0.0.1', 80))


class Test_AIO_UDP(_TestUDP, tb.AIOTestCase):
    pass
