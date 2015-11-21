import asyncio
import socket
import uvloop

from uvloop import _testbase as tb


class _TestTCP:
    pass


class Test_UV_TCP(_TestTCP, tb.UVTestCase):
    pass


class Test_AIO_TCP(_TestTCP, tb.AIOTestCase):
    pass
