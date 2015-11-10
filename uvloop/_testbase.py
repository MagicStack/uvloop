import asyncio
import unittest
import uvloop


class UVTestCase(unittest.TestCase):
    def setUp(self):
        self.loop = uvloop.Loop()
        asyncio.set_event_loop(self.loop)

    def tearDown(self):
        self.loop.close()
        print("here")
        asyncio.set_event_loop(None)
        self.loop = None
