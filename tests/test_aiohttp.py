try:
    import aiohttp
    import aiohttp.server
except ImportError:
    skip_tests = True
else:
    skip_tests = False

import unittest

from uvloop import _testbase as tb


class _TestAioHTTP:

    def test_aiohttp_basic_1(self):

        PAYLOAD = b'<h1>It Works!</h1>' * 10000

        class HttpRequestHandler(aiohttp.server.ServerHttpProtocol):

            async def handle_request(self, message, payload):
                response = aiohttp.Response(
                    self.writer, 200, http_version=message.version
                )
                response.add_header('Content-Type', 'text/html')
                response.add_header('Content-Length', str(len(PAYLOAD)))
                response.send_headers()
                response.write(PAYLOAD)
                await response.write_eof()

        f = self.loop.create_server(
            lambda: HttpRequestHandler(keep_alive=False),
            '0.0.0.0', '0')
        srv = self.loop.run_until_complete(f)

        addr = srv.sockets[0].getsockname()[:2]

        async def test():
            with aiohttp.ClientSession() as client:
                async with client.get('http://{}:{}'.format(*addr)) as resp:
                    self.assertEqual(resp.status, 200)
                    self.assertEqual(len(await resp.text()), len(PAYLOAD))

        self.loop.run_until_complete(test())
        srv.close()
        self.loop.run_until_complete(srv.wait_closed())


@unittest.skipIf(skip_tests, "no aiohttp module")
class Test_UV_AioHTTP(_TestAioHTTP, tb.UVTestCase):
    pass


@unittest.skipIf(skip_tests, "no aiohttp module")
class Test_AIO_AioHTTP(_TestAioHTTP, tb.AIOTestCase):
    pass
