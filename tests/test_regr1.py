import asyncio
import queue
import multiprocessing
import signal
import threading
import unittest

import uvloop

from uvloop import _testbase as tb


class EchoServerProtocol(asyncio.Protocol):

    def connection_made(self, transport):
        transport.write(b'z')


class EchoClientProtocol(asyncio.Protocol):

    def __init__(self, loop):
        self.loop = loop

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.close()

    def connection_lost(self, exc):
        self.loop.stop()


class FailedTestError(BaseException):
    pass


def run_server(quin, qout):
    server_loop = None

    def server_thread():
        nonlocal server_loop
        loop = server_loop = uvloop.new_event_loop()
        asyncio.set_event_loop(loop)
        coro = loop.create_server(EchoServerProtocol, '127.0.0.1', 0)
        server = loop.run_until_complete(coro)
        addr = server.sockets[0].getsockname()
        qout.put(addr)
        loop.run_forever()
        server.close()
        loop.run_until_complete(server.wait_closed())
        try:
            loop.close()
        except Exception as exc:
            print(exc)
        qout.put('stopped')

    thread = threading.Thread(target=server_thread, daemon=True)
    thread.start()

    quin.get()
    server_loop.call_soon_threadsafe(server_loop.stop)
    thread.join(1)


class TestIssue39Regr(tb.UVTestCase):
    """See https://github.com/MagicStack/uvloop/issues/39 for details.

    Original code to reproduce the bug is by Jim Fulton.
    """

    def on_alarm(self, sig, fr):
        if self.running:
            raise FailedTestError

    def run_test(self):
        for i in range(10):
            for threaded in [True, False]:
                if threaded:
                    qin, qout = queue.Queue(), queue.Queue()
                    threading.Thread(
                        target=run_server,
                        args=(qin, qout),
                        daemon=True).start()
                else:
                    qin = multiprocessing.Queue()
                    qout = multiprocessing.Queue()
                    multiprocessing.Process(
                        target=run_server,
                        args=(qin, qout),
                        daemon=True).start()

                addr = qout.get()
                loop = self.new_loop()
                asyncio.set_event_loop(loop)
                loop.create_task(
                    loop.create_connection(
                        lambda: EchoClientProtocol(loop),
                        host=addr[0], port=addr[1]))
                loop.run_forever()
                loop.close()
                qin.put('stop')
                qout.get()

    @unittest.skipIf(
        multiprocessing.get_start_method(False) == 'spawn',
        'no need to test on macOS where spawn is used instead of fork')
    def test_issue39_regression(self):
        signal.signal(signal.SIGALRM, self.on_alarm)
        signal.alarm(5)

        try:
            self.running = True
            self.run_test()
        except FailedTestError:
            self.fail('deadlocked in libuv')
        finally:
            self.running = False
            signal.signal(signal.SIGALRM, signal.SIG_IGN)
