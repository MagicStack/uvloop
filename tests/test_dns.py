import socket
import unittest

from uvloop import _testbase as tb


_HOST, _PORT = ('example.com', 80)
_NON_HOST, _NON_PORT = ('a' + '1' * 50 + '.wat', 800)


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
        self._test_getaddrinfo(_HOST, _PORT)

    def test_getaddrinfo_2(self):
        self._test_getaddrinfo(_HOST, _PORT, flags=socket.AI_CANONNAME)

    def test_getaddrinfo_3(self):
        self._test_getaddrinfo(_NON_HOST, _NON_PORT)

    def test_getaddrinfo_4(self):
        self._test_getaddrinfo(_HOST, _PORT, family=-1)

    def test_getaddrinfo_5(self):
        self._test_getaddrinfo(_HOST, str(_PORT))

    def test_getaddrinfo_6(self):
        self._test_getaddrinfo(_HOST.encode(), str(_PORT).encode())

    def test_getaddrinfo_7(self):
        self._test_getaddrinfo(None, 0)

    def test_getaddrinfo_8(self):
        self._test_getaddrinfo('', 0)

    def test_getaddrinfo_9(self):
        self._test_getaddrinfo(b'', 0)

    def test_getaddrinfo_10(self):
        self._test_getaddrinfo(None, None)

    def test_getaddrinfo_11(self):
        self._test_getaddrinfo(_HOST.encode(), str(_PORT))

    def test_getaddrinfo_12(self):
        self._test_getaddrinfo(_HOST.encode(), str(_PORT).encode())

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
        try:
            # Check that we have internet connection
            socket.getaddrinfo(_HOST, _PORT)
        except socket.error:
            raise unittest.SkipTest

        async def run():
            fut = self.loop.getaddrinfo(_HOST, _PORT)
            fut.cancel()
            self.loop.stop()

        try:
            self.loop.run_until_complete(run())
        finally:
            self.loop.close()


class Test_AIO_DNS(BaseTestDNS, tb.AIOTestCase):

    def test_getaddrinfo_11(self):
        self._test_getaddrinfo(_HOST.encode(), str(_PORT))
