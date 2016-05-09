import asyncio
import socket
import uvloop
import sys

from asyncio import test_utils
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
    def test_create_datagram_endpoint_addrs(self):
        class TestMyDatagramProto(MyDatagramProto):
            def __init__(inner_self):
                super().__init__(loop=self.loop)

            def datagram_received(self, data, addr):
                super().datagram_received(data, addr)
                self.transport.sendto(b'resp:' + data, addr)

        for lc in (('127.0.0.1', 0), None):
            if lc is None and not isinstance(self.loop, uvloop.Loop):
                # TODO This looks like a bug in asyncio -- if no local_addr
                # and no remote_addr are specified, the connection
                # that asyncio creates is not bound anywhere.
                return

            with self.subTest(local_addr=lc):
                coro = self.loop.create_datagram_endpoint(
                    TestMyDatagramProto, local_addr=lc, family=socket.AF_INET)
                s_transport, server = self.loop.run_until_complete(coro)
                host, port = s_transport.get_extra_info('sockname')

                self.assertIsInstance(server, TestMyDatagramProto)
                self.assertEqual('INITIALIZED', server.state)
                self.assertIs(server.transport, s_transport)

                extra = {}
                if hasattr(socket, 'SO_REUSEPORT') and \
                        sys.version_info[:3] >= (3, 5, 1):
                    extra['reuse_port'] = True

                coro = self.loop.create_datagram_endpoint(
                    lambda: MyDatagramProto(loop=self.loop),
                    family=socket.AF_INET,
                    remote_addr=None if lc is None else (host, port),
                    **extra)
                transport, client = self.loop.run_until_complete(coro)

                self.assertIsInstance(client, MyDatagramProto)
                self.assertEqual('INITIALIZED', client.state)
                self.assertIs(client.transport, transport)

                transport.sendto(b'xxx', (host, port) if lc is None else None)
                test_utils.run_until(self.loop, lambda: server.nbytes)
                self.assertEqual(3, server.nbytes)
                test_utils.run_until(self.loop, lambda: client.nbytes)

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
            except:
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


class Test_UV_UDP(_TestUDP, tb.UVTestCase):
    pass


class Test_AIO_UDP(_TestUDP, tb.AIOTestCase):
    pass
