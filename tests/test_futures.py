import asyncio
import logging
import threading
import time
import unittest

import uvloop
from uvloop.futures import Future as CFuture

from unittest import mock
from uvloop._testbase import UVTestCase


class TestFutures(UVTestCase):

    def test_set_result(self):
        f = CFuture(self.loop)
        f.set_result(1)
        with self.assertRaises(asyncio.InvalidStateError):
            f.set_result(1)

    def test_cancel(self):
        f = CFuture(self.loop)
        self.assertTrue(f.cancel())
        self.assertTrue(f.cancelled())
        self.assertTrue(f.done())
        self.assertRaises(asyncio.CancelledError, f.result)
        self.assertRaises(asyncio.CancelledError, f.exception)
        self.assertRaises(asyncio.InvalidStateError, f.set_result, None)
        self.assertRaises(asyncio.InvalidStateError, f.set_exception, None)
        self.assertFalse(f.cancel())

    def test_initial_state(self):
        f = CFuture(loop=self.loop)
        self.assertFalse(f.cancelled())
        self.assertFalse(f.done())
        f.cancel()
        self.assertTrue(f.cancelled())

    def test_result(self):
        f = CFuture(self.loop)
        self.assertRaises(asyncio.InvalidStateError, f.result)

        f.set_result(42)
        self.assertFalse(f.cancelled())
        self.assertTrue(f.done())
        self.assertEqual(f.result(), 42)
        self.assertEqual(f.exception(), None)
        self.assertRaises(asyncio.InvalidStateError, f.set_result, None)
        self.assertRaises(asyncio.InvalidStateError, f.set_exception, None)
        self.assertFalse(f.cancel())

    def test_exception(self):
        exc = RuntimeError()
        f = CFuture(self.loop)
        self.assertRaises(asyncio.InvalidStateError, f.exception)

        f.set_exception(exc)
        self.assertFalse(f.cancelled())
        self.assertTrue(f.done())
        self.assertRaises(RuntimeError, f.result)
        self.assertEqual(f.exception(), exc)
        self.assertRaises(asyncio.InvalidStateError, f.set_result, None)
        self.assertRaises(asyncio.InvalidStateError, f.set_exception, None)
        self.assertFalse(f.cancel())

    def test_blocking(self):
        f = CFuture(self.loop)
        self.assertFalse(f._blocking)
        f._blocking = True
        self.assertTrue(f._blocking)
        f._blocking = 0
        self.assertFalse(f._blocking)

    def test_yield_from_twice(self):
        f = CFuture(self.loop)

        def fixture():
            yield 'A'
            x = yield from f
            yield 'B', x
            y = yield from f
            yield 'C', y

        g = fixture()
        self.assertEqual(next(g), 'A')  # yield 'A'.
        self.assertEqual(next(g), f)  # First yield from f.
        f.set_result(42)
        self.assertEqual(next(g), ('B', 42))  # yield 'B', x.
        # The second "yield from f" does not yield f.
        self.assertEqual(next(g), ('C', 42))  # yield 'C', y.

    def test_iter(self):
        fut = CFuture(self.loop)

        def coro():
            yield from fut

        def test():
            arg1, arg2 = coro()

        self.assertRaises(RuntimeError, test)
        fut.cancel()


class FutureDoneCallbackTests(UVTestCase):

    def _make_callback(self, fut, bag, thing):
        # Create a callback function that appends thing to bag.
        def bag_appender(future):
            self.assertIs(future, fut)
            bag.append(thing)
        return bag_appender

    def _new_future(self):
        return CFuture(self.loop)

    def run_briefly(self):
        self.loop.call_later(0.01, lambda: self.loop.stop())
        self.loop.run_forever()

    def test_callbacks_invoked_on_set_result(self):
        bag = []
        f = self._new_future()
        f.add_done_callback(self._make_callback(f, bag, 42))
        f.add_done_callback(self._make_callback(f, bag, 17))

        self.assertEqual(bag, [])
        f.set_result('foo')

        self.run_briefly()

        self.assertEqual(bag, [42, 17])
        self.assertEqual(f.result(), 'foo')

    def test_callbacks_invoked_on_set_exception(self):
        bag = []
        f = self._new_future()
        f.add_done_callback(self._make_callback(f, bag, 100))

        self.assertEqual(bag, [])
        exc = RuntimeError()
        f.set_exception(exc)

        self.run_briefly()

        self.assertEqual(bag, [100])
        self.assertEqual(f.exception(), exc)


@unittest.skipIf(not uvloop._CFUTURE,
                 'uvloop was not compiled with USE_C_FUTURE')
class FutureIntegrationTests(UVTestCase):

    def test_ensure_future(self):
        f = CFuture(self.loop)
        self.assertIs(f, asyncio.ensure_future(f))

    def test_wrap_future(self):
        f = CFuture(self.loop)
        self.assertIs(f, asyncio.wrap_future(f))
