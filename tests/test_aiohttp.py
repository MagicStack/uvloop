try:
    import aiohttp
    import aiohttp.web
except ImportError:
    skip_tests = True
else:
    skip_tests = False

import asyncio
import unittest

from uvloop import _testbase as tb


class _TestAioHTTP:

    def test_aiohttp_basic_1(self):

        PAYLOAD = '<h1>It Works!</h1>' * 10000

        async def on_request(request):
            return aiohttp.web.Response(text=PAYLOAD)

        asyncio.set_event_loop(self.loop)
        app = aiohttp.web.Application()
        app.router.add_get('/', on_request)

        f = self.loop.create_server(
            app.make_handler(),
            '0.0.0.0', '0')
        srv = self.loop.run_until_complete(f)

        port = srv.sockets[0].getsockname()[1]

        async def test():
            # Make sure we're using the correct event loop.
            self.assertIs(asyncio.get_event_loop(), self.loop)

            for addr in (('localhost', port),
                         ('127.0.0.1', port)):
                async with aiohttp.ClientSession() as client:
                    async with client.get('http://{}:{}'.format(*addr)) as r:
                        self.assertEqual(r.status, 200)
                        result = await r.text()
                        self.assertEqual(result, PAYLOAD)

        self.loop.run_until_complete(test())
        self.loop.run_until_complete(app.shutdown())
        self.loop.run_until_complete(app.cleanup())

        srv.close()
        self.loop.run_until_complete(srv.wait_closed())


@unittest.skipIf(skip_tests, "no aiohttp module")
class Test_UV_AioHTTP(_TestAioHTTP, tb.UVTestCase):
    pass


@unittest.skipIf(skip_tests, "no aiohttp module")
class Test_AIO_AioHTTP(_TestAioHTTP, tb.AIOTestCase):
    pass
