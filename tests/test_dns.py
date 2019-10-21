import asyncio
import socket
import unittest
from tempfile import mktemp

from uvloop import _testbase as tb


class BaseTestDNS:

    def _test_getaddrinfo(self, *args, **kwargs):
        err = None
        try:
            a1 = socket.getaddrinfo(*args, **kwargs)
        except socket.gaierror as ex:
            err = ex

        try:
            a2 = self.loop.run_until_complete(
                self.loop.getaddrinfo(*args, **kwargs))
        except socket.gaierror as ex:
            if err is not None:
                self.assertEqual(ex.args, err.args)
            else:
                ex.__context__ = err
                raise ex
        except OSError as ex:
            ex.__context__ = err
            raise ex
        else:
            if err is not None:
                raise err

            self.assertEqual(a1, a2)

    def _test_getnameinfo(self, *args, **kwargs):
        err = None
        try:
            a1 = socket.getnameinfo(*args, **kwargs)
        except Exception as ex:
            err = ex

        try:
            a2 = self.loop.run_until_complete(
                self.loop.getnameinfo(*args, **kwargs))
        except Exception as ex:
            if err is not None:
                if ex.__class__ is not err.__class__:
                    print(ex, err)
                self.assertIs(ex.__class__, err.__class__)
                self.assertEqual(ex.args, err.args)
            else:
                raise
        else:
            if err is not None:
                raise err

            self.assertEqual(a1, a2)

    def test_getaddrinfo_1(self):
        self._test_getaddrinfo('example.com', 80)
        self._test_getaddrinfo('example.com', 80, type=socket.SOCK_STREAM)

    def test_getaddrinfo_2(self):
        self._test_getaddrinfo('example.com', 80, flags=socket.AI_CANONNAME)

    def test_getaddrinfo_3(self):
        self._test_getaddrinfo('a' + '1' * 50 + '.wat', 800)

    def test_getaddrinfo_4(self):
        self._test_getaddrinfo('example.com', 80, family=-1)
        self._test_getaddrinfo('example.com', 80, type=socket.SOCK_STREAM,
                               family=-1)

    def test_getaddrinfo_5(self):
        self._test_getaddrinfo('example.com', '80')
        self._test_getaddrinfo('example.com', '80', type=socket.SOCK_STREAM)

    def test_getaddrinfo_6(self):
        self._test_getaddrinfo(b'example.com', b'80')
        self._test_getaddrinfo(b'example.com', b'80', type=socket.SOCK_STREAM)

    def test_getaddrinfo_7(self):
        self._test_getaddrinfo(None, 0)
        self._test_getaddrinfo(None, 0, type=socket.SOCK_STREAM)

    def test_getaddrinfo_8(self):
        self._test_getaddrinfo('', 0)
        self._test_getaddrinfo('', 0, type=socket.SOCK_STREAM)

    def test_getaddrinfo_9(self):
        self._test_getaddrinfo(b'', 0)
        self._test_getaddrinfo(b'', 0, type=socket.SOCK_STREAM)

    def test_getaddrinfo_10(self):
        self._test_getaddrinfo(None, None)
        self._test_getaddrinfo(None, None, type=socket.SOCK_STREAM)

    def test_getaddrinfo_11(self):
        self._test_getaddrinfo(b'example.com', '80')
        self._test_getaddrinfo(b'example.com', '80', type=socket.SOCK_STREAM)

    def test_getaddrinfo_12(self):
        self._test_getaddrinfo('127.0.0.1', '80')
        self._test_getaddrinfo('127.0.0.1', '80', type=socket.SOCK_STREAM)

    def test_getaddrinfo_13(self):
        self._test_getaddrinfo(b'127.0.0.1', b'80')
        self._test_getaddrinfo(b'127.0.0.1', b'80', type=socket.SOCK_STREAM)

    def test_getaddrinfo_14(self):
        self._test_getaddrinfo(b'127.0.0.1', b'http')
        self._test_getaddrinfo(b'127.0.0.1', b'http', type=socket.SOCK_STREAM)

    def test_getaddrinfo_15(self):
        self._test_getaddrinfo('127.0.0.1', 'http')
        self._test_getaddrinfo('127.0.0.1', 'http', type=socket.SOCK_STREAM)

    def test_getaddrinfo_16(self):
        self._test_getaddrinfo('localhost', 'http')
        self._test_getaddrinfo('localhost', 'http', type=socket.SOCK_STREAM)

    def test_getaddrinfo_17(self):
        self._test_getaddrinfo(b'localhost', 'http')
        self._test_getaddrinfo(b'localhost', 'http', type=socket.SOCK_STREAM)

    def test_getaddrinfo_18(self):
        self._test_getaddrinfo('localhost', b'http')
        self._test_getaddrinfo('localhost', b'http', type=socket.SOCK_STREAM)

    def test_getaddrinfo_19(self):
        self._test_getaddrinfo('::1', 80)
        self._test_getaddrinfo('::1', 80, type=socket.SOCK_STREAM)

    def test_getaddrinfo_20(self):
        self._test_getaddrinfo('127.0.0.1', 80)
        self._test_getaddrinfo('127.0.0.1', 80, type=socket.SOCK_STREAM)

    ######

    def test_getnameinfo_1(self):
        self._test_getnameinfo(('127.0.0.1', 80), 0)

    def test_getnameinfo_2(self):
        self._test_getnameinfo(('127.0.0.1', 80, 1231231231213), 0)

    def test_getnameinfo_3(self):
        self._test_getnameinfo(('127.0.0.1', 80, 0, 0), 0)

    def test_getnameinfo_4(self):
        self._test_getnameinfo(('::1', 80), 0)

    def test_getnameinfo_5(self):
        self._test_getnameinfo(('localhost', 8080), 0)


class Test_UV_DNS(BaseTestDNS, tb.UVTestCase):

    def test_getaddrinfo_close_loop(self):
        # Test that we can close the loop with a running
        # DNS query.

        try:
            # Check that we have internet connection
            socket.getaddrinfo('example.com', 80)
        except socket.error:
            raise unittest.SkipTest

        async def run():
            fut = self.loop.create_task(
                self.loop.getaddrinfo('example.com', 80))
            await asyncio.sleep(0, loop=self.loop)
            fut.cancel()
            self.loop.stop()

        try:
            self.loop.run_until_complete(run())
        finally:
            self.loop.close()


class Test_AIO_DNS(BaseTestDNS, tb.AIOTestCase):
    pass


class TestUnixUDPServer(tb.UVTestCase):
    def test_unix_socket(self):
        class UDPProtocol:
            packets = []
            event = None

            def connection_made(self, transport):
                self.transport = transport

            def connection_lost(self, transport):
                pass

            def datagram_received(self, data, addr):
                self.packets.append((data, addr))
                self.event.set()

        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock_path = mktemp(suffix='.sock')
            sock.bind(sock_path)

            async def run():
                transport, protocol = await self.loop.create_datagram_endpoint(
                    UDPProtocol, sock=sock
                )

                UDPProtocol.event = asyncio.Event(loop=self.loop)
                transport.sendto(b'Hello', sock_path)
                await asyncio.wait_for(UDPProtocol.event.wait(), timeout=2)
                transport.close()

            self.loop.run_until_complete(run())
            assert UDPProtocol.packets
