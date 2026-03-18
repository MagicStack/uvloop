import asyncio
import os
import signal
import subprocess
import sys
import time
import unittest

from uvloop import _testbase as tb

DELAY = 0.1


class _TestSignal:
    NEW_LOOP = None

    @tb.silence_long_exec_warning()
    def test_signals_sigint_pycode_stop(self):
        async def runner():
            PROG = (
                R"""\
import asyncio
import uvloop
import time

from uvloop import _testbase as tb

async def worker():
    print('READY', flush=True)
    time.sleep(200)

@tb.silence_long_exec_warning()
def run():
    loop = """
                + self.NEW_LOOP
                + """
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(worker())
    finally:
        loop.close()

run()
"""
            )

            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                b"-W",
                b"ignore",
                b"-c",
                PROG,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            await proc.stdout.readline()
            time.sleep(DELAY)
            if sys.platform == "win32" and self.NEW_LOOP == "asyncio.new_event_loop()":
                proc.send_signal(signal.SIGTERM)  # alt: proc.terminate()
            else:
                proc.send_signal(signal.SIGINT)
            out, err = await proc.communicate()
            if sys.platform == "win32":
                self.assertEqual(err, b"")
            else:
                self.assertIn(b"KeyboardInterrupt", err)
            self.assertEqual(out, b"")

        self.loop.run_until_complete(runner())

    @tb.silence_long_exec_warning()
    def test_signals_sigint_pycode_continue(self):
        async def runner():
            PROG = (
                R"""\
import asyncio
import uvloop
import time

from uvloop import _testbase as tb

async def worker():
    print('READY', flush=True)
    try:
        time.sleep(200)
    except KeyboardInterrupt:
        print("oups")
    await asyncio.sleep(0.5)
    print('done')

@tb.silence_long_exec_warning()
def run():
    loop = """
                + self.NEW_LOOP
                + """
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(worker())
    finally:
        loop.close()

run()
"""
            )

            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                b"-W",
                b"ignore",
                b"-c",
                PROG,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            await proc.stdout.readline()
            time.sleep(DELAY)
            if sys.platform == "win32" and self.NEW_LOOP == "asyncio.new_event_loop()":
                proc.send_signal(signal.SIGTERM)  # alt: proc.terminate()
            else:
                proc.send_signal(signal.SIGINT)
            out, err = await proc.communicate()
            self.assertEqual(err, b"")
            if sys.platform == "win32":
                self.assertEqual(out, b"")
            else:
                self.assertEqual(out, b"oups\ndone\n")

        self.loop.run_until_complete(runner())

    @tb.silence_long_exec_warning()
    def test_signals_sigint_uvcode(self):
        async def runner():
            PROG = (
                R"""\
import asyncio
import uvloop

srv = None

async def worker():
    global srv
    cb = lambda *args: None
    srv = await asyncio.start_server(cb, '127.0.0.1', 0)
    print('READY', flush=True)

loop = """
                + self.NEW_LOOP
                + """
asyncio.set_event_loop(loop)
loop.create_task(worker())
try:
    loop.run_forever()
finally:
    srv.close()
    loop.run_until_complete(srv.wait_closed())
    loop.close()
"""
            )

            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                b"-W",
                b"ignore",
                b"-c",
                PROG,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            await proc.stdout.readline()
            time.sleep(DELAY)
            if sys.platform == "win32" and self.NEW_LOOP == "asyncio.new_event_loop()":
                proc.send_signal(signal.SIGTERM)  # alt: proc.terminate()
            else:
                proc.send_signal(signal.SIGINT)
            out, err = await proc.communicate()
            if sys.platform == "win32":
                self.assertEqual(err, b"")
            else:
                self.assertIn(b"KeyboardInterrupt", err)

        self.loop.run_until_complete(runner())

    @tb.silence_long_exec_warning()
    def test_signals_sigint_uvcode_two_loop_runs(self):
        async def runner():
            PROG = (
                R"""\
import asyncio
import uvloop

srv = None

async def worker():
    global srv
    cb = lambda *args: None
    srv = await asyncio.start_server(cb, '127.0.0.1', 0)

loop = """
                + self.NEW_LOOP
                + """
asyncio.set_event_loop(loop)
loop.run_until_complete(worker())
print('READY', flush=True)
try:
    loop.run_forever()
finally:
    srv.close()
    loop.run_until_complete(srv.wait_closed())
    loop.close()
"""
            )

            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                b"-W",
                b"ignore",
                b"-c",
                PROG,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            await proc.stdout.readline()
            time.sleep(DELAY)
            if sys.platform == "win32" and self.NEW_LOOP == "asyncio.new_event_loop()":
                proc.send_signal(signal.SIGTERM)  # alt: proc.terminate()
            else:
                proc.send_signal(signal.SIGINT)
            out, err = await proc.communicate()
            if sys.platform == "win32":
                self.assertEqual(err, b"")
            else:
                self.assertIn(b"KeyboardInterrupt", err)

        self.loop.run_until_complete(runner())

    # uvloop comment: next two tests use add_signal_handler(), which
    # is not supported by asyncio on Windows. Further, signal.SIGHUP
    # not available on Windows.
    @unittest.skipIf(sys.platform == "win32", "no SIGHUP etc. on Windows")
    @tb.silence_long_exec_warning()
    def test_signals_sigint_and_custom_handler(self):
        async def runner():
            PROG = (
                R"""\
import asyncio
import signal
import uvloop

srv = None

async def worker():
    global srv
    cb = lambda *args: None
    srv = await asyncio.start_server(cb, '127.0.0.1', 0)
    print('READY', flush=True)

def handler_sig(say):
    print(say, flush=True)
    exit()

def handler_hup(say):
    print(say, flush=True)

loop = """
                + self.NEW_LOOP
                + """
loop.add_signal_handler(signal.SIGINT, handler_sig, '!s-int!')
loop.add_signal_handler(signal.SIGHUP, handler_hup, '!s-hup!')
asyncio.set_event_loop(loop)
loop.create_task(worker())
try:
    loop.run_forever()
finally:
    srv.close()
    loop.run_until_complete(srv.wait_closed())
    loop.close()
"""
            )

            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                b"-W",
                b"ignore",
                b"-c",
                PROG,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            await proc.stdout.readline()
            time.sleep(DELAY)
            proc.send_signal(signal.SIGHUP)
            time.sleep(DELAY)
            proc.send_signal(signal.SIGINT)
            out, err = await proc.communicate()
            self.assertEqual(err, b"")
            self.assertIn(b"!s-hup!", out)
            self.assertIn(b"!s-int!", out)

        self.loop.run_until_complete(runner())

    @unittest.skipIf(sys.platform == "win32", "no SIGHUP etc. on Windows")
    @tb.silence_long_exec_warning()
    def test_signals_and_custom_handler_1(self):
        async def runner():
            PROG = (
                R"""\
import asyncio
import signal
import uvloop

srv = None

async def worker():
    global srv
    cb = lambda *args: None
    srv = await asyncio.start_server(cb, '127.0.0.1', 0)
    print('READY', flush=True)

def handler1():
    print("GOTIT", flush=True)

def handler2():
    assert loop.remove_signal_handler(signal.SIGUSR1)
    print("REMOVED", flush=True)

def handler_hup():
    exit()

loop = """
                + self.NEW_LOOP
                + """
asyncio.set_event_loop(loop)
loop.add_signal_handler(signal.SIGUSR1, handler1)
loop.add_signal_handler(signal.SIGUSR2, handler2)
loop.add_signal_handler(signal.SIGHUP, handler_hup)
loop.create_task(worker())
try:
    loop.run_forever()
finally:
    srv.close()
    loop.run_until_complete(srv.wait_closed())
    loop.close()

"""
            )

            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                b"-W",
                b"ignore",
                b"-c",
                PROG,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            await proc.stdout.readline()

            time.sleep(DELAY)
            proc.send_signal(signal.SIGUSR1)
            time.sleep(DELAY)
            proc.send_signal(signal.SIGUSR1)
            time.sleep(DELAY)
            proc.send_signal(signal.SIGUSR2)
            time.sleep(DELAY)
            proc.send_signal(signal.SIGUSR1)
            time.sleep(DELAY)
            proc.send_signal(signal.SIGUSR1)
            time.sleep(DELAY)
            proc.send_signal(signal.SIGHUP)

            out, err = await proc.communicate()
            self.assertEqual(err, b"")
            self.assertEqual(b"GOTIT\nGOTIT\nREMOVED\n", out)

        self.loop.run_until_complete(runner())

    @unittest.skipIf(sys.platform == "win32", "no SIGKILL on Windows")
    def test_signals_invalid_signal(self):
        with self.assertRaisesRegex(
            RuntimeError, "sig {} cannot be caught".format(signal.SIGKILL)
        ):
            self.loop.add_signal_handler(signal.SIGKILL, lambda *a: None)

    def test_signals_coro_callback(self):
        if sys.platform == "win32" and self.NEW_LOOP == "asyncio.new_event_loop()":
            raise unittest.SkipTest("no add_signal_handler on asyncio loop on Windows")

        async def coro():
            pass

        with self.assertRaisesRegex(TypeError, "coroutines cannot be used"):
            if sys.platform == "win32":
                # uvloop comment: use (arbitrary) signal defined on Windows
                self.loop.add_signal_handler(signal.SIGILL, coro)
            else:
                self.loop.add_signal_handler(signal.SIGHUP, coro)

    def test_signals_wakeup_fd_unchanged(self):
        # uvloop comment: below, the assignments to fd0 and loop are swapped
        # to pass this test on Windows; also works with Linux,
        # but need to double check this.
        async def runner():
            PROG = (
                R"""\
import uvloop
import signal
import asyncio


def get_wakeup_fd():
    fd = signal.set_wakeup_fd(-1)
    signal.set_wakeup_fd(fd)
    return fd

async def f(): pass

loop = """
                + self.NEW_LOOP
                + """
fd0 = get_wakeup_fd()
try:
    asyncio.set_event_loop(loop)
    loop.run_until_complete(f())
    fd1 = get_wakeup_fd()
finally:
    loop.close()

print(fd0 == fd1, flush=True)

"""
            )

            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                b"-W",
                b"ignore",
                b"-c",
                PROG,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            out, err = await proc.communicate()
            self.assertEqual(err, b"")
            self.assertIn(b"True", out)

        self.loop.run_until_complete(runner())

    def test_signals_fork_in_thread(self):
        if sys.platform == "win32" and self.NEW_LOOP == "asyncio.new_event_loop()":
            raise unittest.SkipTest("no add_signal_handler on asyncio loop on Windows")

        # Refs #452, when forked from a thread, the main-thread-only signal
        # operations failed thread ID checks because we didn't update
        # MAIN_THREAD_ID after fork. It's now a lazy value set when needed and
        # cleared after fork.
        PROG = (
            R"""\
import asyncio
import multiprocessing
import signal
import sys
import threading
import uvloop

#multiprocessing.set_start_method('fork')

def subprocess():
    loop = """
            + self.NEW_LOOP
            + """
    loop.add_signal_handler(signal.SIGINT, lambda *a: None)

def run():
    loop = """
            + self.NEW_LOOP
            + """
    loop.add_signal_handler(signal.SIGINT, lambda *a: None)
    p = multiprocessing.Process(target=subprocess)
    t = threading.Thread(target=p.start)
    t.start()
    t.join()
    p.join()
    sys.exit(p.exitcode)

if __name__ == "__main__":
    run()
"""
        )

        # uvloop comment: in PROG above we use default setting
        # for start_method: on Linux 'fork' and on Windows 'spawn'.
        # Also, avoid call run() during import.
        if sys.platform != "win32":
            subprocess.check_call(
                [
                    sys.executable,
                    b"-W",
                    b"ignore",
                    b"-c",
                    PROG,
                ]
            )
        else:
            # uvloop comment: spawn uses pickle on subprocess()
            # but this gives an error like:
            # "...   self = reduction.pickle.load(from_parent)
            # AttributeError: Can't get attribute 'subprocess'
            # on <module '__main__' (built-in)>"
            # Therefore we run PROG as a script.
            with open("tempfiletstsig.py", "wt") as f:
                f.write(PROG)
            subprocess.check_call(
                [sys.executable, b"-W", b"ignore", b"tempfiletstsig.py"]
            )
            os.remove("tempfiletstsig.py")


class Test_UV_Signals(_TestSignal, tb.UVTestCase):
    NEW_LOOP = "uvloop.new_event_loop()"

    @unittest.skipIf(sys.platform == "win32", "no SIGCHLD on Windows")
    def test_signals_no_SIGCHLD(self):
        with self.assertRaisesRegex(RuntimeError, r"cannot add.*handler.*SIGCHLD"):
            self.loop.add_signal_handler(signal.SIGCHLD, lambda *a: None)


class Test_AIO_Signals(_TestSignal, tb.AIOTestCase):
    NEW_LOOP = "asyncio.new_event_loop()"
