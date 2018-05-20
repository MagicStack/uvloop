import unittest

from uvloop import tracing, TracingCollector


class TestTracingCollector(unittest.TestCase):
    def test_tracing_methods(self):
        collector = TracingCollector()
        assert hasattr(collector, 'dns_request_begin')
        assert hasattr(collector, 'dns_request_end')


class TestTracing(unittest.TestCase):
    def test_invalid_collector(self):
        with self.assertRaises(ValueError):
            with tracing(None):
                pass
