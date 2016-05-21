import asyncio
import logging
import threading
import time
import uvloop
import unittest
import weakref

from unittest import mock
from uvloop._testbase import UVTestCase, AIOTestCase


class _TestBase:

    def test_close(self):
        self.assertFalse(self.loop._closed)
        self.assertFalse(self.loop.is_closed())
        self.loop.close()
        self.assertTrue(self.loop._closed)
        self.assertTrue(self.loop.is_closed())

        # it should be possible to call close() more than once
        self.loop.close()
        self.loop.close()

        # operation blocked when the loop is closed
        f = asyncio.Future(loop=self.loop)
        self.assertRaises(RuntimeError, self.loop.run_forever)
        self.assertRaises(RuntimeError, self.loop.run_until_complete, f)

    def test_handle_weakref(self):
        wd = weakref.WeakValueDictionary()
        h = self.loop.call_soon(lambda: None)
        wd['h'] = h  # Would fail without __weakref__ slot.

    def test_call_soon(self):
        calls = []

        def cb(inc):
            calls.append(inc)
            self.loop.stop()

        self.loop.call_soon(cb, 10)

        h = self.loop.call_soon(cb, 100)
        self.assertIn('.cb', repr(h))
        h.cancel()
        self.assertIn('cancelled', repr(h))

        self.loop.call_soon(cb, 1)

        self.loop.run_forever()

        self.assertEqual(calls, [10, 1])

    def test_call_soon_base_exc(self):
        def cb():
            raise KeyboardInterrupt()

        self.loop.call_soon(cb)

        with self.assertRaises(KeyboardInterrupt):
            self.loop.run_forever()

        self.assertFalse(self.loop.is_closed())

    def test_calls_debug_reporting(self):
        def run_test(debug, meth, stack_adj):
            context = None

            def handler(loop, ctx):
                nonlocal context
                context = ctx

            self.loop.set_debug(debug)
            self.loop.set_exception_handler(handler)

            def cb():
                1 / 0

            meth(cb)
            self.assertIsNone(context)
            self.loop.run_until_complete(asyncio.sleep(0.05, loop=self.loop))

            self.assertIs(type(context['exception']), ZeroDivisionError)
            self.assertTrue(context['message'].startswith(
                'Exception in callback'))

            if debug:
                tb = context['source_traceback']
                self.assertEqual(tb[-1 + stack_adj].name, 'run_test')
            else:
                self.assertFalse('source_traceback' in context)

        for flag in (True, False):
            for meth_name, meth, stack_adj in (
                ('call_soon',
                    self.loop.call_soon, 0),
                ('call_later',  # `-1` accounts for lambda
                    lambda *args: self.loop.call_later(0.01, *args), -1)
            ):
                with self.subTest(debug=flag, meth_name=meth_name):
                    run_test(flag, meth, stack_adj)

    def test_now_update(self):
        async def run():
            st = self.loop.time()
            time.sleep(0.05)
            return self.loop.time() - st

        delta = self.loop.run_until_complete(run())
        self.assertTrue(delta > 0.049 and delta < 0.6)

    def test_call_later(self):
        calls = []

        def cb(inc=10, stop=False):
            calls.append(inc)
            self.assertTrue(self.loop.is_running())
            if stop:
                self.loop.call_soon(self.loop.stop)

        self.loop.call_later(0.05, cb)

        # canceled right away
        h = self.loop.call_later(0.05, cb, 100, True)
        self.assertIn('.cb', repr(h))
        h.cancel()
        self.assertIn('cancelled', repr(h))

        self.loop.call_later(0.05, cb, 1, True)
        self.loop.call_later(1000, cb, 1000)  # shouldn't be called

        started = time.monotonic()
        self.loop.run_forever()
        finished = time.monotonic()

        self.assertLess(finished - started, 0.1)
        self.assertGreater(finished - started, 0.04)

        self.assertEqual(calls, [10, 1])

        self.assertFalse(self.loop.is_running())

    def test_call_later_negative(self):
        calls = []

        def cb(arg):
            calls.append(arg)
            self.loop.stop()

        self.loop.call_later(-1, cb, 'a')
        self.loop.run_forever()
        self.assertEqual(calls, ['a'])

    def test_call_at(self):
        i = 0

        def cb(inc):
            nonlocal i
            i += inc
            self.loop.stop()

        at = self.loop.time() + 0.05

        self.loop.call_at(at, cb, 100).cancel()
        self.loop.call_at(at, cb, 10)

        started = time.monotonic()
        self.loop.run_forever()
        finished = time.monotonic()

        self.assertLess(finished - started, 0.07)
        self.assertGreater(finished - started, 0.045)

        self.assertEqual(i, 10)

    def test_check_thread(self):
        def check_thread(loop, debug):
            def cb():
                pass

            loop.set_debug(debug)
            if debug:
                msg = ("Non-thread-safe operation invoked on an "
                       "event loop other than the current one")
                with self.assertRaisesRegex(RuntimeError, msg):
                    loop.call_soon(cb)
                with self.assertRaisesRegex(RuntimeError, msg):
                    loop.call_later(60, cb)
                with self.assertRaisesRegex(RuntimeError, msg):
                    loop.call_at(loop.time() + 60, cb)
            else:
                loop.call_soon(cb)
                loop.call_later(60, cb)
                loop.call_at(loop.time() + 60, cb)

        def check_in_thread(loop, event, debug, create_loop, fut):
            # wait until the event loop is running
            event.wait()

            try:
                if create_loop:
                    loop2 = self.new_loop()
                    try:
                        asyncio.set_event_loop(loop2)
                        check_thread(loop, debug)
                    finally:
                        asyncio.set_event_loop(None)
                        loop2.close()
                else:
                    check_thread(loop, debug)
            except Exception as exc:
                loop.call_soon_threadsafe(fut.set_exception, exc)
            else:
                loop.call_soon_threadsafe(fut.set_result, None)

        def test_thread(loop, debug, create_loop=False):
            event = threading.Event()
            fut = asyncio.Future(loop=loop)
            loop.call_soon(event.set)
            args = (loop, event, debug, create_loop, fut)
            thread = threading.Thread(target=check_in_thread, args=args)
            thread.start()
            loop.run_until_complete(fut)
            thread.join()

        # raise RuntimeError if the thread has no event loop
        test_thread(self.loop, True)

        # check disabled if debug mode is disabled
        test_thread(self.loop, False)

        # raise RuntimeError if the event loop of the thread is not the called
        # event loop
        test_thread(self.loop, True, create_loop=True)

        # check disabled if debug mode is disabled
        test_thread(self.loop, False, create_loop=True)

    def test_run_once_in_executor_plain(self):
        called = []

        def cb(arg):
            called.append(arg)

        async def runner():
            await self.loop.run_in_executor(None, cb, 'a')

        self.loop.run_until_complete(runner())

        self.assertEqual(called, ['a'])

    def test_set_debug(self):
        self.loop.set_debug(True)
        self.assertTrue(self.loop.get_debug())
        self.loop.set_debug(False)
        self.assertFalse(self.loop.get_debug())

    def test_run_until_complete_type_error(self):
        self.assertRaises(
            TypeError, self.loop.run_until_complete, 'blah')

    def test_run_until_complete_loop(self):
        task = asyncio.Future(loop=self.loop)
        other_loop = self.new_loop()
        self.addCleanup(other_loop.close)
        self.assertRaises(
            ValueError, other_loop.run_until_complete, task)

    def test_run_until_complete_error(self):
        async def foo():
            raise ValueError('aaa')
        with self.assertRaisesRegex(ValueError, 'aaa'):
            self.loop.run_until_complete(foo())

    def test_default_exc_handler_callback(self):
        self.loop._process_events = mock.Mock()

        def zero_error(fut):
            fut.set_result(True)
            1 / 0

        logger = logging.getLogger('asyncio')

        # Test call_soon (events.Handle)
        with mock.patch.object(logger, 'error') as log:
            fut = asyncio.Future(loop=self.loop)
            self.loop.call_soon(zero_error, fut)
            fut.add_done_callback(lambda fut: self.loop.stop())
            self.loop.run_forever()
            log.assert_called_with(
                self.mock_pattern('Exception in callback.*zero'),
                exc_info=mock.ANY)

        # Test call_later (events.TimerHandle)
        with mock.patch.object(logger, 'error') as log:
            fut = asyncio.Future(loop=self.loop)
            self.loop.call_later(0.01, zero_error, fut)
            fut.add_done_callback(lambda fut: self.loop.stop())
            self.loop.run_forever()
            log.assert_called_with(
                self.mock_pattern('Exception in callback.*zero'),
                exc_info=mock.ANY)

    def test_set_exc_handler_custom(self):
        logger = logging.getLogger('asyncio')

        def run_loop():
            def zero_error():
                self.loop.stop()
                1 / 0
            self.loop.call_soon(zero_error)
            self.loop.run_forever()

        errors = []

        def handler(loop, exc):
            errors.append(exc)

        self.loop.set_debug(True)

        if hasattr(self.loop, 'get_exception_handler'):
            # Available since Python 3.5.2
            self.assertIsNone(self.loop.get_exception_handler())
        self.loop.set_exception_handler(handler)
        if hasattr(self.loop, 'get_exception_handler'):
            self.assertIs(self.loop.get_exception_handler(), handler)
        run_loop()
        self.assertEqual(len(errors), 1)
        self.assertRegex(errors[-1]['message'],
                         'Exception in callback.*zero_error')

        self.loop.set_exception_handler(None)
        with mock.patch.object(logger, 'error') as log:
            run_loop()
            log.assert_called_with(
                self.mock_pattern('Exception in callback.*zero'),
                exc_info=mock.ANY)

        self.assertEqual(len(errors), 1)

    def test_set_exc_handler_broken(self):
        logger = logging.getLogger('asyncio')

        def run_loop():
            def zero_error():
                self.loop.stop()
                1 / 0
            self.loop.call_soon(zero_error)
            self.loop.run_forever()

        def handler(loop, context):
            raise AttributeError('spam')

        self.loop._process_events = mock.Mock()

        self.loop.set_exception_handler(handler)

        with mock.patch.object(logger, 'error') as log:
            run_loop()
            log.assert_called_with(
                self.mock_pattern('Unhandled error in exception handler'),
                exc_info=mock.ANY)

    def test_default_exc_handler_broken(self):
        logger = logging.getLogger('asyncio')
        _context = None

        class Loop(uvloop.Loop):

            _selector = mock.Mock()
            _process_events = mock.Mock()

            def default_exception_handler(self, context):
                nonlocal _context
                _context = context
                # Simulates custom buggy "default_exception_handler"
                raise ValueError('spam')

        loop = Loop()
        self.addCleanup(loop.close)
        asyncio.set_event_loop(loop)

        def run_loop():
            def zero_error():
                loop.stop()
                1 / 0
            loop.call_soon(zero_error)
            loop.run_forever()

        with mock.patch.object(logger, 'error') as log:
            run_loop()
            log.assert_called_with(
                'Exception in default exception handler',
                exc_info=True)

        def custom_handler(loop, context):
            raise ValueError('ham')

        _context = None
        loop.set_exception_handler(custom_handler)
        with mock.patch.object(logger, 'error') as log:
            run_loop()
            log.assert_called_with(
                self.mock_pattern('Exception in default exception.*'
                                  'while handling.*in custom'),
                exc_info=True)

            # Check that original context was passed to default
            # exception handler.
            self.assertIn('context', _context)
            self.assertIs(type(_context['context']['exception']),
                          ZeroDivisionError)

    def test_set_task_factory_invalid(self):
        with self.assertRaisesRegex(
                TypeError,
                'task factory must be a callable or None'):

            self.loop.set_task_factory(1)

        self.assertIsNone(self.loop.get_task_factory())

    def test_set_task_factory(self):
        self.loop._process_events = mock.Mock()

        class MyTask(asyncio.Task):
            pass

        @asyncio.coroutine
        def coro():
            pass

        factory = lambda loop, coro: MyTask(coro, loop=loop)

        self.assertIsNone(self.loop.get_task_factory())
        self.loop.set_task_factory(factory)
        self.assertIs(self.loop.get_task_factory(), factory)

        task = self.loop.create_task(coro())
        self.assertTrue(isinstance(task, MyTask))
        self.loop.run_until_complete(task)

        self.loop.set_task_factory(None)
        self.assertIsNone(self.loop.get_task_factory())

        task = self.loop.create_task(coro())
        self.assertTrue(isinstance(task, asyncio.Task))
        self.assertFalse(isinstance(task, MyTask))
        self.loop.run_until_complete(task)


class TestBaseUV(_TestBase, UVTestCase):

    def test_loop_create_future(self):
        fut = self.loop.create_future()
        self.assertTrue(isinstance(fut, asyncio.Future))
        self.assertIs(fut._loop, self.loop)
        fut.cancel()


class TestBaseAIO(_TestBase, AIOTestCase):
    pass


class TestPolicy(unittest.TestCase):

    def test_uvloop_policy(self):
        try:
            asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
            loop = asyncio.new_event_loop()
            try:
                self.assertIsInstance(loop, uvloop.Loop)
            finally:
                loop.close()
        finally:
            asyncio.set_event_loop_policy(None)
