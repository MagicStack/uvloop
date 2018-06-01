# LICENSE: PSF.

import asyncio
import sys
import unittest

from uvloop import _testbase as tb


PY37 = sys.version_info >= (3, 7, 0)


if PY37:
    from uvloop import tracing, TracingCollector


class TestTracingCollector(unittest.TestCase):
    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_tracing_methods(self):
        collector = TracingCollector()
        assert hasattr(collector, 'dns_request_begin')
        assert hasattr(collector, 'dns_request_end')
        assert hasattr(collector, 'task_created')


class TestTracing(tb.UVTestCase):

    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_invalid_collector(self):
        with self.assertRaises(ValueError):
            with tracing(None):
                pass

    @unittest.skipIf(PY37, 'requires Python <3.7')
    def test_none_compatible_python_version(self):
        from uvloop.loop import tracing
        with self.assertRaises(NotImplementedError):
            with tracing(None):
                pass

    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_multiple_collectors(self):

        @asyncio.coroutine
        def coro():
            pass

        class Collector(TracingCollector):
            task_created_called = 0

            def task_created(self, *args):
                self.task_created_called += 1

        collector_a = Collector()
        with tracing(collector_a):
            collector_b = Collector()
            with tracing(collector_b):
                self.loop.create_task(coro())
                assert collector_a.task_created_called == 1
                assert collector_b.task_created_called == 1

            self.loop.create_task(coro())
            assert collector_a.task_created_called == 2
            assert collector_b.task_created_called == 1

        self.loop.create_task(coro())
        assert collector_a.task_created_called == 2
        assert collector_b.task_created_called == 1

        tb.run_briefly(self.loop)

    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_collectors_do_not_break_the_execution(self):

        @asyncio.coroutine
        def coro():
            pass

        class Collector(TracingCollector):
            def task_created(self, *args):
                raise Exception()

        with tracing(Collector()):
            self.loop.create_task(coro())

        tb.run_briefly(self.loop)
