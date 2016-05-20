# LICENSE: PSF.

import asyncio
import concurrent.futures
import re
import sys
import threading
import unittest
import uvloop

from asyncio import test_utils
from uvloop import _testbase as tb
from unittest import mock
from test import support


# Most of the tests are copied from asyncio


def _fakefunc(f):
    return f


def first_cb():
    pass


def last_cb():
    pass


class _TestFutures:

    def create_future(self):
        raise NotImplementedError

    def test_future_initial_state(self):
        f = self.create_future()
        self.assertFalse(f.cancelled())
        self.assertFalse(f.done())
        f.cancel()
        self.assertTrue(f.cancelled())

    def test_future_cancel(self):
        f = self.create_future()
        self.assertTrue(f.cancel())
        self.assertTrue(f.cancelled())
        self.assertTrue(f.done())
        self.assertRaises(asyncio.CancelledError, f.result)
        self.assertRaises(asyncio.CancelledError, f.exception)
        self.assertRaises(asyncio.InvalidStateError, f.set_result, None)
        self.assertRaises(asyncio.InvalidStateError, f.set_exception, None)
        self.assertFalse(f.cancel())

    def test_future_result(self):
        f = self.create_future()
        self.assertRaises(asyncio.InvalidStateError, f.result)

        f.set_result(42)
        self.assertFalse(f.cancelled())
        self.assertTrue(f.done())
        self.assertEqual(f.result(), 42)
        self.assertEqual(f.exception(), None)
        self.assertRaises(asyncio.InvalidStateError, f.set_result, None)
        self.assertRaises(asyncio.InvalidStateError, f.set_exception, None)
        self.assertFalse(f.cancel())

    def test_future_exception(self):
        exc = RuntimeError()
        f = self.create_future()
        self.assertRaises(asyncio.InvalidStateError, f.exception)

        if sys.version_info[:3] > (3, 5, 1):
            # StopIteration cannot be raised into a Future - CPython issue26221
            self.assertRaisesRegex(TypeError,
                                   "StopIteration .* cannot be raised",
                                   f.set_exception, StopIteration)

        f.set_exception(exc)
        self.assertFalse(f.cancelled())
        self.assertTrue(f.done())
        self.assertRaises(RuntimeError, f.result)
        self.assertEqual(f.exception(), exc)
        self.assertRaises(asyncio.InvalidStateError, f.set_result, None)
        self.assertRaises(asyncio.InvalidStateError, f.set_exception, None)
        self.assertFalse(f.cancel())

    def test_future_exception_class(self):
        f = self.create_future()
        f.set_exception(RuntimeError)
        self.assertIsInstance(f.exception(), RuntimeError)

    def test_future_yield_from_twice(self):
        f = self.create_future()

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

    def test_future_repr(self):
        self.loop.set_debug(True)
        f_pending_debug = self.create_future()
        frame = f_pending_debug._source_traceback[-1]
        self.assertEqual(repr(f_pending_debug),
                         '<Future pending created at %s:%s>'
                         % (frame[0], frame[1]))
        f_pending_debug.cancel()

        self.loop.set_debug(False)
        f_pending = self.create_future()
        self.assertEqual(repr(f_pending), '<Future pending>')
        f_pending.cancel()

        f_cancelled = self.create_future()
        f_cancelled.cancel()
        self.assertEqual(repr(f_cancelled), '<Future cancelled>')

        f_result = self.create_future()
        f_result.set_result(4)
        self.assertEqual(repr(f_result), '<Future finished result=4>')
        self.assertEqual(f_result.result(), 4)

        exc = RuntimeError()
        f_exception = self.create_future()
        f_exception.set_exception(exc)
        self.assertEqual(repr(f_exception),
                         '<Future finished exception=RuntimeError()>')
        self.assertIs(f_exception.exception(), exc)

        def func_repr(func):
            filename, lineno = test_utils.get_function_source(func)
            text = '%s() at %s:%s' % (func.__qualname__, filename, lineno)
            return re.escape(text)

        f_one_callbacks = self.create_future()
        f_one_callbacks.add_done_callback(_fakefunc)
        fake_repr = func_repr(_fakefunc)
        self.assertRegex(repr(f_one_callbacks),
                         r'<Future pending cb=\[%s\]>' % fake_repr)
        f_one_callbacks.cancel()
        self.assertEqual(repr(f_one_callbacks),
                         '<Future cancelled>')

        f_two_callbacks = self.create_future()
        f_two_callbacks.add_done_callback(first_cb)
        f_two_callbacks.add_done_callback(last_cb)
        first_repr = func_repr(first_cb)
        last_repr = func_repr(last_cb)
        self.assertRegex(repr(f_two_callbacks),
                         r'<Future pending cb=\[%s, %s\]>'
                         % (first_repr, last_repr))

        f_many_callbacks = self.create_future()
        f_many_callbacks.add_done_callback(first_cb)
        for i in range(8):
            f_many_callbacks.add_done_callback(_fakefunc)
        f_many_callbacks.add_done_callback(last_cb)
        cb_regex = r'%s, <8 more>, %s' % (first_repr, last_repr)
        self.assertRegex(repr(f_many_callbacks),
                         r'<Future pending cb=\[%s\]>' % cb_regex)
        f_many_callbacks.cancel()
        self.assertEqual(repr(f_many_callbacks),
                         '<Future cancelled>')

    def test_future_copy_state(self):
        if sys.version_info[:3] < (3, 5, 1):
            raise unittest.SkipTest()

        from asyncio.futures import _copy_future_state

        f = self.create_future()
        f.set_result(10)

        newf = self.create_future()
        _copy_future_state(f, newf)
        self.assertTrue(newf.done())
        self.assertEqual(newf.result(), 10)

        f_exception = self.create_future()
        f_exception.set_exception(RuntimeError())

        newf_exception = self.create_future()
        _copy_future_state(f_exception, newf_exception)
        self.assertTrue(newf_exception.done())
        self.assertRaises(RuntimeError, newf_exception.result)

        f_cancelled = self.create_future()
        f_cancelled.cancel()

        newf_cancelled = self.create_future()
        _copy_future_state(f_cancelled, newf_cancelled)
        self.assertTrue(newf_cancelled.cancelled())

    @mock.patch('asyncio.base_events.logger')
    def test_future_tb_logger_abandoned(self, m_log):
        fut = self.create_future()
        del fut
        self.assertFalse(m_log.error.called)

    @mock.patch('asyncio.base_events.logger')
    def test_future_tb_logger_result_unretrieved(self, m_log):
        fut = self.create_future()
        fut.set_result(42)
        del fut
        self.assertFalse(m_log.error.called)

    @mock.patch('asyncio.base_events.logger')
    def test_future_tb_logger_result_retrieved(self, m_log):
        fut = self.create_future()
        fut.set_result(42)
        fut.result()
        del fut
        self.assertFalse(m_log.error.called)

    def test_future_wrap_future(self):
        def run(arg):
            return (arg, threading.get_ident())
        ex = concurrent.futures.ThreadPoolExecutor(1)
        f1 = ex.submit(run, 'oi')
        f2 = asyncio.wrap_future(f1, loop=self.loop)
        res, ident = self.loop.run_until_complete(f2)
        self.assertIsInstance(f2, asyncio.Future)
        self.assertEqual(res, 'oi')
        self.assertNotEqual(ident, threading.get_ident())

    def test_future_wrap_future_future(self):
        f1 = self.create_future()
        f2 = asyncio.wrap_future(f1)
        self.assertIs(f1, f2)

    def test_future_wrap_future_use_global_loop(self):
        with mock.patch('asyncio.futures.events') as events:
            events.get_event_loop = lambda: self.loop
            def run(arg):
                return (arg, threading.get_ident())
            ex = concurrent.futures.ThreadPoolExecutor(1)
            f1 = ex.submit(run, 'oi')
            f2 = asyncio.wrap_future(f1)
            self.assertIs(self.loop, f2._loop)

    def test_future_wrap_future_cancel(self):
        f1 = concurrent.futures.Future()
        f2 = asyncio.wrap_future(f1, loop=self.loop)
        f2.cancel()
        test_utils.run_briefly(self.loop)
        self.assertTrue(f1.cancelled())
        self.assertTrue(f2.cancelled())

    def test_future_wrap_future_cancel2(self):
        f1 = concurrent.futures.Future()
        f2 = asyncio.wrap_future(f1, loop=self.loop)
        f1.set_result(42)
        f2.cancel()
        test_utils.run_briefly(self.loop)
        self.assertFalse(f1.cancelled())
        self.assertEqual(f1.result(), 42)
        self.assertTrue(f2.cancelled())

    def test_future_source_traceback(self):
        self.loop.set_debug(True)

        future = self.create_future()
        lineno = sys._getframe().f_lineno - 1
        self.assertIsInstance(future._source_traceback, list)
        self.assertEqual(future._source_traceback[-2][:3],
                         (__file__,
                          lineno,
                          'test_future_source_traceback'))

    def check_future_exception_never_retrieved(self, debug):
        last_ctx = None
        def handler(loop, context):
            nonlocal last_ctx
            last_ctx = context

        self.loop.set_debug(debug)
        self.loop.set_exception_handler(handler)

        def memory_error():
            try:
                raise MemoryError()
            except BaseException as exc:
                return exc
        exc = memory_error()

        future = self.create_future()
        if debug:
            source_traceback = future._source_traceback
        future.set_exception(exc)
        future = None
        support.gc_collect()
        test_utils.run_briefly(self.loop)

        self.assertIsNotNone(last_ctx)

        self.assertIs(last_ctx['exception'], exc)
        self.assertEqual(last_ctx['message'],
                         'Future exception was never retrieved')

        if debug:
            tb = last_ctx['source_traceback']
            self.assertEqual(tb[-2].name,
                             'check_future_exception_never_retrieved')

    def test_future_exception_never_retrieved(self):
        self.check_future_exception_never_retrieved(False)

    def test_future_exception_never_retrieved_debug(self):
        self.check_future_exception_never_retrieved(True)

    def test_future_wrap_future(self):
        from uvloop.loop import _wrap_future
        def run(arg):
            return (arg, threading.get_ident())
        ex = concurrent.futures.ThreadPoolExecutor(1)
        f1 = ex.submit(run, 'oi')
        f2 = _wrap_future(f1, loop=self.loop)
        res, ident = self.loop.run_until_complete(f2)
        self.assertIsInstance(f2, asyncio.Future)
        self.assertEqual(res, 'oi')
        self.assertNotEqual(ident, threading.get_ident())

    def test_future_wrap_future_future(self):
        from uvloop.loop import _wrap_future
        f1 = self.create_future()
        f2 = _wrap_future(f1)
        self.assertIs(f1, f2)

    def test_future_wrap_future_cancel(self):
        from uvloop.loop import _wrap_future
        f1 = concurrent.futures.Future()
        f2 = _wrap_future(f1, loop=self.loop)
        f2.cancel()
        test_utils.run_briefly(self.loop)
        self.assertTrue(f1.cancelled())
        self.assertTrue(f2.cancelled())

    def test_future_wrap_future_cancel2(self):
        from uvloop.loop import _wrap_future
        f1 = concurrent.futures.Future()
        f2 = _wrap_future(f1, loop=self.loop)
        f1.set_result(42)
        f2.cancel()
        test_utils.run_briefly(self.loop)
        self.assertFalse(f1.cancelled())
        self.assertEqual(f1.result(), 42)
        self.assertTrue(f2.cancelled())


class _TestFuturesDoneCallbacks:

    def run_briefly(self):
        test_utils.run_briefly(self.loop)

    def _make_callback(self, bag, thing):
        # Create a callback function that appends thing to bag.
        def bag_appender(future):
            bag.append(thing)
        return bag_appender

    def _new_future(self):
        raise NotImplementedError

    def test_future_callbacks_invoked_on_set_result(self):
        bag = []
        f = self._new_future()
        f.add_done_callback(self._make_callback(bag, 42))
        f.add_done_callback(self._make_callback(bag, 17))

        self.assertEqual(bag, [])
        f.set_result('foo')

        self.run_briefly()

        self.assertEqual(bag, [42, 17])
        self.assertEqual(f.result(), 'foo')

    def test_future_callbacks_invoked_on_set_exception(self):
        bag = []
        f = self._new_future()
        f.add_done_callback(self._make_callback(bag, 100))

        self.assertEqual(bag, [])
        exc = RuntimeError()
        f.set_exception(exc)

        self.run_briefly()

        self.assertEqual(bag, [100])
        self.assertEqual(f.exception(), exc)

    def test_future_remove_done_callback(self):
        bag = []
        f = self._new_future()
        cb1 = self._make_callback(bag, 1)
        cb2 = self._make_callback(bag, 2)
        cb3 = self._make_callback(bag, 3)

        # Add one cb1 and one cb2.
        f.add_done_callback(cb1)
        f.add_done_callback(cb2)

        # One instance of cb2 removed. Now there's only one cb1.
        self.assertEqual(f.remove_done_callback(cb2), 1)

        # Never had any cb3 in there.
        self.assertEqual(f.remove_done_callback(cb3), 0)

        # After this there will be 6 instances of cb1 and one of cb2.
        f.add_done_callback(cb2)
        for i in range(5):
            f.add_done_callback(cb1)

        # Remove all instances of cb1. One cb2 remains.
        self.assertEqual(f.remove_done_callback(cb1), 6)

        self.assertEqual(bag, [])
        f.set_result('foo')

        self.run_briefly()

        self.assertEqual(bag, [2])
        self.assertEqual(f.result(), 'foo')


###############################################################################
# Tests Matrix
###############################################################################


class Test_UV_UV_create_future(_TestFutures, tb.UVTestCase):
    # Test uvloop.Loop.create_future
    def create_future(self):
        return self.loop.create_future()


class Test_UV_UV_Future(_TestFutures, tb.UVTestCase):
    # Test that uvloop.Future can be instantiated directly
    def create_future(self):
        return uvloop.Future(loop=self.loop)


class Test_UV_AIO_Futures(_TestFutures, tb.UVTestCase):
    def create_future(self):
        return asyncio.Future(loop=self.loop)


class Test_AIO_Futures(_TestFutures, tb.AIOTestCase):
    def create_future(self):
        return asyncio.Future(loop=self.loop)


class Test_UV_UV_FuturesCallbacks(_TestFuturesDoneCallbacks, tb.UVTestCase):
    def _new_future(self):
        return self.loop.create_future()


class Test_UV_AIO_FuturesCallbacks(_TestFuturesDoneCallbacks, tb.UVTestCase):
    def _new_future(self):
        return asyncio.Future(loop=self.loop)


class Test_AIO_FuturesCallbacks(_TestFuturesDoneCallbacks, tb.AIOTestCase):
    def _new_future(self):
        return asyncio.Future(loop=self.loop)
