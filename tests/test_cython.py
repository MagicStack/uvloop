import asyncio

from uvloop._testbase import UVTestCase


class TestCythonIntegration(UVTestCase):

    def test_cython_coro_is_coroutine(self):
        from uvloop.loop import _test_coroutine_1
        from asyncio.coroutines import _format_coroutine

        coro = _test_coroutine_1()

        self.assertTrue(
            _format_coroutine(coro).startswith('_test_coroutine_1() done'))
        self.assertEqual(_test_coroutine_1.__qualname__, '_test_coroutine_1')
        self.assertEqual(_test_coroutine_1.__name__, '_test_coroutine_1')
        self.assertTrue(asyncio.iscoroutine(coro))
        fut = asyncio.ensure_future(coro)
        self.assertTrue(isinstance(fut, asyncio.Future))
        self.assertTrue(isinstance(fut, asyncio.Task))
        fut.cancel()

        with self.assertRaises(asyncio.CancelledError):
            self.loop.run_until_complete(fut)

        try:
            _format_coroutine(coro)  # This line checks against Cython segfault
        except TypeError:
            # TODO: Fix Cython to not reset __name__/__qualname__ to None
            pass
        coro.close()
