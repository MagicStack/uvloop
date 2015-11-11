import asyncio
import re
import unittest
import uvloop


class MockPattern(str):
    def __eq__(self, other):
        return bool(re.search(str(self), other, re.S))


class BaseTestCase(unittest.TestCase):

    def new_loop(self):
        raise NotImplementedError

    def mock_pattern(self, str):
        return MockPattern(str)

    def setUp(self):
        self.loop = self.new_loop()
        asyncio.set_event_loop(self.loop)

    def tearDown(self):
        self.loop.close()
        asyncio.set_event_loop(None)
        self.loop = None


class UVTestCase(BaseTestCase):

    def new_loop(self):
        return uvloop.Loop()


class AIOTestCase(BaseTestCase):

    def new_loop(self):
        return asyncio.new_event_loop()
