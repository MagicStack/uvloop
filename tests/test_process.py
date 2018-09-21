import asyncio
import contextlib
import gc
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest

import psutil

from uvloop import _testbase as tb


class _TestProcess:
    def get_num_fds(self):
        return psutil.Process(os.getpid()).num_fds()

    def test_process_env_1(self):
        async def test():
            cmd = 'echo $FOO$BAR'
            env = {'FOO': 'sp', 'BAR': 'am'}
            proc = await asyncio.create_subprocess_shell(
                cmd,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                loop=self.loop)

            out, _ = await proc.communicate()
            self.assertEqual(out, b'spam\n')
            self.assertEqual(proc.returncode, 0)

        self.loop.run_until_complete(test())

    def test_process_cwd_1(self):
        async def test():
            cmd = 'pwd'
            env = {}
            cwd = '/'
            proc = await asyncio.create_subprocess_shell(
                cmd,
                cwd=cwd,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                loop=self.loop)

            out, _ = await proc.communicate()
            self.assertEqual(out, b'/\n')
            self.assertEqual(proc.returncode, 0)

        self.loop.run_until_complete(test())

    @unittest.skipUnless(hasattr(os, 'fspath'), 'no os.fspath()')
    def test_process_cwd_2(self):
        async def test():
            cmd = 'pwd'
            env = {}
            cwd = pathlib.Path('/')
            proc = await asyncio.create_subprocess_shell(
                cmd,
                cwd=cwd,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                loop=self.loop)

            out, _ = await proc.communicate()
            self.assertEqual(out, b'/\n')
            self.assertEqual(proc.returncode, 0)

        self.loop.run_until_complete(test())

    def test_process_preexec_fn_1(self):
        # Copied from CPython/test_suprocess.py

        # DISCLAIMER: Setting environment variables is *not* a good use
        # of a preexec_fn.  This is merely a test.

        async def test():
            cmd = sys.executable
            proc = await asyncio.create_subprocess_exec(
                cmd, b'-W', b'ignore', '-c',
                'import os,sys;sys.stdout.write(os.getenv("FRUIT"))',
                stdout=subprocess.PIPE,
                preexec_fn=lambda: os.putenv("FRUIT", "apple"),
                loop=self.loop)

            out, _ = await proc.communicate()
            self.assertEqual(out, b'apple')
            self.assertEqual(proc.returncode, 0)

        self.loop.run_until_complete(test())

    def test_process_preexec_fn_2(self):
        # Copied from CPython/test_suprocess.py

        def raise_it():
            raise ValueError("spam")

        async def test():
            cmd = sys.executable
            proc = await asyncio.create_subprocess_exec(
                cmd, b'-W', b'ignore', '-c', 'import time; time.sleep(10)',
                preexec_fn=raise_it,
                loop=self.loop)

            await proc.communicate()

        started = time.time()
        try:
            self.loop.run_until_complete(test())
        except subprocess.SubprocessError as ex:
            self.assertIn('preexec_fn', ex.args[0])
            if ex.__cause__ is not None:
                # uvloop will set __cause__
                self.assertIs(type(ex.__cause__), ValueError)
                self.assertEqual(ex.__cause__.args[0], 'spam')
        else:
            self.fail(
                'exception in preexec_fn did not propagate to the parent')

        if time.time() - started > 5:
            self.fail(
                'exception in preexec_fn did not kill the child process')

    def test_process_executable_1(self):
        async def test():
            proc = await asyncio.create_subprocess_exec(
                b'doesnotexist', b'-W', b'ignore', b'-c', b'print("spam")',
                executable=sys.executable,
                stdout=subprocess.PIPE,
                loop=self.loop)

            out, err = await proc.communicate()
            self.assertEqual(out, b'spam\n')

        self.loop.run_until_complete(test())

    def test_process_pid_1(self):
        async def test():
            prog = '''\
import os
print(os.getpid())
            '''

            cmd = sys.executable
            proc = await asyncio.create_subprocess_exec(
                cmd, b'-W', b'ignore', b'-c', prog,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                loop=self.loop)

            pid = proc.pid
            expected_result = '{}\n'.format(pid).encode()

            out, err = await proc.communicate()
            self.assertEqual(out, expected_result)

        self.loop.run_until_complete(test())

    def test_process_send_signal_1(self):
        async def test():
            prog = '''\
import signal

def handler(signum, frame):
    if signum == signal.SIGUSR1:
        print('WORLD')

signal.signal(signal.SIGUSR1, handler)
a = input()
print(a)
a = input()
print(a)
exit(11)
            '''

            cmd = sys.executable
            proc = await asyncio.create_subprocess_exec(
                cmd, b'-W', b'ignore', b'-c', prog,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                loop=self.loop)

            proc.stdin.write(b'HELLO\n')
            await proc.stdin.drain()

            self.assertEqual(await proc.stdout.readline(), b'HELLO\n')

            proc.send_signal(signal.SIGUSR1)

            proc.stdin.write(b'!\n')
            await proc.stdin.drain()

            self.assertEqual(await proc.stdout.readline(), b'WORLD\n')
            self.assertEqual(await proc.stdout.readline(), b'!\n')
            self.assertEqual(await proc.wait(), 11)

        self.loop.run_until_complete(test())

    def test_process_streams_basic_1(self):
        async def test():

            prog = '''\
import sys
while True:
    a = input()
    if a == 'stop':
        exit(20)
    elif a == 'stderr':
        print('OUCH', file=sys.stderr)
    else:
        print('>' + a + '<')
            '''

            cmd = sys.executable
            proc = await asyncio.create_subprocess_exec(
                cmd, b'-W', b'ignore', b'-c', prog,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                loop=self.loop)

            self.assertGreater(proc.pid, 0)
            self.assertIs(proc.returncode, None)

            transp = proc._transport
            with self.assertRaises(NotImplementedError):
                # stdin is WriteTransport
                transp.get_pipe_transport(0).pause_reading()
            with self.assertRaises((NotImplementedError, AttributeError)):
                # stdout is ReadTransport
                transp.get_pipe_transport(1).write(b'wat')

            proc.stdin.write(b'foobar\n')
            await proc.stdin.drain()
            out = await proc.stdout.readline()
            self.assertEqual(out, b'>foobar<\n')

            proc.stdin.write(b'stderr\n')
            await proc.stdin.drain()
            out = await proc.stderr.readline()
            self.assertEqual(out, b'OUCH\n')

            proc.stdin.write(b'stop\n')
            await proc.stdin.drain()

            exitcode = await proc.wait()
            self.assertEqual(exitcode, 20)

        self.loop.run_until_complete(test())

    def test_process_streams_stderr_to_stdout(self):
        async def test():
            prog = '''\
import sys
print('out', flush=True)
print('err', file=sys.stderr, flush=True)
            '''

            proc = await asyncio.create_subprocess_exec(
                sys.executable, b'-W', b'ignore', b'-c', prog,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                loop=self.loop)

            out, err = await proc.communicate()
            self.assertIsNone(err)
            self.assertEqual(out, b'out\nerr\n')

        self.loop.run_until_complete(test())

    def test_process_streams_devnull(self):
        async def test():
            prog = '''\
import sys
print('out', flush=True)
print('err', file=sys.stderr, flush=True)
            '''

            proc = await asyncio.create_subprocess_exec(
                sys.executable, b'-W', b'ignore', b'-c', prog,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                loop=self.loop)

            out, err = await proc.communicate()
            self.assertIsNone(err)
            self.assertIsNone(out)

        self.loop.run_until_complete(test())

    def test_process_streams_pass_fds(self):
        async def test():
            prog = '''\
import sys, os
assert sys.argv[1] == '--'
inherited = int(sys.argv[2])
non_inherited = int(sys.argv[3])

os.fstat(inherited)

try:
    os.fstat(non_inherited)
except:
    pass
else:
    raise RuntimeError()

print("OK")
            '''

            with tempfile.TemporaryFile() as inherited, \
                    tempfile.TemporaryFile() as non_inherited:

                proc = await asyncio.create_subprocess_exec(
                    sys.executable, b'-W', b'ignore', b'-c', prog, '--',
                    str(inherited.fileno()),
                    str(non_inherited.fileno()),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    pass_fds=(inherited.fileno(),),
                    loop=self.loop)

                out, err = await proc.communicate()
                self.assertEqual(err, b'')
                self.assertEqual(out, b'OK\n')

        self.loop.run_until_complete(test())

    def test_subprocess_fd_leak_1(self):
        async def main(n):
            for i in range(n):
                try:
                    await asyncio.create_subprocess_exec(
                        'nonexistant',
                        loop=self.loop,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL)
                except FileNotFoundError:
                    pass
                await asyncio.sleep(0, loop=self.loop)

        self.loop.run_until_complete(main(10))
        num_fd_1 = self.get_num_fds()
        self.loop.run_until_complete(main(10))
        num_fd_2 = self.get_num_fds()

        self.assertEqual(num_fd_1, num_fd_2)

    def test_subprocess_fd_leak_2(self):
        async def main(n):
            for i in range(n):
                try:
                    p = await asyncio.create_subprocess_exec(
                        'ls',
                        loop=self.loop,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL)
                finally:
                    await p.wait()
                await asyncio.sleep(0, loop=self.loop)

        self.loop.run_until_complete(main(10))
        num_fd_1 = self.get_num_fds()
        self.loop.run_until_complete(main(10))
        num_fd_2 = self.get_num_fds()

        self.assertEqual(num_fd_1, num_fd_2)

    def test_subprocess_invalid_stdin(self):
        fd = None
        for tryfd in range(10000, 1000, -1):
            try:
                tryfd = os.dup(tryfd)
            except OSError:
                fd = tryfd
                break
            else:
                os.close(tryfd)
        else:
            self.fail('could not find a free FD')

        async def main():
            with self.assertRaises(OSError):
                await asyncio.create_subprocess_exec(
                    'ls',
                    loop=self.loop,
                    stdin=fd)

            with self.assertRaises(OSError):
                await asyncio.create_subprocess_exec(
                    'ls',
                    loop=self.loop,
                    stdout=fd)

            with self.assertRaises(OSError):
                await asyncio.create_subprocess_exec(
                    'ls',
                    loop=self.loop,
                    stderr=fd)

        self.loop.run_until_complete(main())


class _AsyncioTests:

    # Program blocking
    PROGRAM_BLOCKED = [sys.executable, b'-W', b'ignore',
                       b'-c', b'import time; time.sleep(3600)']

    # Program copying input to output
    PROGRAM_CAT = [
        sys.executable, b'-c',
        b';'.join((b'import sys',
                   b'data = sys.stdin.buffer.read()',
                   b'sys.stdout.buffer.write(data)'))]

    PROGRAM_ERROR = [
        sys.executable, b'-W', b'ignore', b'-c', b'1/0'
    ]

    def test_stdin_not_inheritable(self):
        # asyncio issue #209: stdin must not be inheritable, otherwise
        # the Process.communicate() hangs
        @asyncio.coroutine
        def len_message(message):
            code = 'import sys; data = sys.stdin.read(); print(len(data))'
            proc = yield from asyncio.create_subprocess_exec(
                sys.executable, b'-W', b'ignore', b'-c', code,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                close_fds=False,
                loop=self.loop)
            stdout, stderr = yield from proc.communicate(message)
            exitcode = yield from proc.wait()
            return (stdout, exitcode)

        output, exitcode = self.loop.run_until_complete(len_message(b'abc'))
        self.assertEqual(output.rstrip(), b'3')
        self.assertEqual(exitcode, 0)

    def test_stdin_stdout_pipe(self):
        args = self.PROGRAM_CAT

        @asyncio.coroutine
        def run(data):
            proc = yield from asyncio.create_subprocess_exec(
                *args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                loop=self.loop)

            # feed data
            proc.stdin.write(data)
            yield from proc.stdin.drain()
            proc.stdin.close()

            # get output and exitcode
            data = yield from proc.stdout.read()
            exitcode = yield from proc.wait()
            return (exitcode, data)

        task = run(b'some data')
        task = asyncio.wait_for(task, 60.0, loop=self.loop)
        exitcode, stdout = self.loop.run_until_complete(task)
        self.assertEqual(exitcode, 0)
        self.assertEqual(stdout, b'some data')

    def test_stdin_stdout_file(self):
        args = self.PROGRAM_CAT

        @asyncio.coroutine
        def run(data, stdout):
            proc = yield from asyncio.create_subprocess_exec(
                *args,
                stdin=subprocess.PIPE,
                stdout=stdout,
                loop=self.loop)

            # feed data
            proc.stdin.write(data)
            yield from proc.stdin.drain()
            proc.stdin.close()

            exitcode = yield from proc.wait()
            return exitcode

        with tempfile.TemporaryFile('w+b') as new_stdout:
            task = run(b'some data', new_stdout)
            task = asyncio.wait_for(task, 60.0, loop=self.loop)
            exitcode = self.loop.run_until_complete(task)
            self.assertEqual(exitcode, 0)

            new_stdout.seek(0)
            self.assertEqual(new_stdout.read(), b'some data')

    def test_stdin_stderr_file(self):
        args = self.PROGRAM_ERROR

        @asyncio.coroutine
        def run(stderr):
            proc = yield from asyncio.create_subprocess_exec(
                *args,
                stdin=subprocess.PIPE,
                stderr=stderr,
                loop=self.loop)

            exitcode = yield from proc.wait()
            return exitcode

        with tempfile.TemporaryFile('w+b') as new_stderr:
            task = run(new_stderr)
            task = asyncio.wait_for(task, 60.0, loop=self.loop)
            exitcode = self.loop.run_until_complete(task)
            self.assertEqual(exitcode, 1)

            new_stderr.seek(0)
            self.assertIn(b'ZeroDivisionError', new_stderr.read())

    def test_communicate(self):
        args = self.PROGRAM_CAT

        @asyncio.coroutine
        def run(data):
            proc = yield from asyncio.create_subprocess_exec(
                *args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                loop=self.loop)
            stdout, stderr = yield from proc.communicate(data)
            return proc.returncode, stdout

        task = run(b'some data')
        task = asyncio.wait_for(task, 60.0, loop=self.loop)
        exitcode, stdout = self.loop.run_until_complete(task)
        self.assertEqual(exitcode, 0)
        self.assertEqual(stdout, b'some data')

    def test_start_new_session(self):
        # start the new process in a new session
        create = asyncio.create_subprocess_shell('exit 8',
                                                 start_new_session=True,
                                                 loop=self.loop)
        proc = self.loop.run_until_complete(create)
        exitcode = self.loop.run_until_complete(proc.wait())
        self.assertEqual(exitcode, 8)

    def test_shell(self):
        create = asyncio.create_subprocess_shell('exit 7',
                                                 loop=self.loop)
        proc = self.loop.run_until_complete(create)
        exitcode = self.loop.run_until_complete(proc.wait())
        self.assertEqual(exitcode, 7)

    def test_kill(self):
        args = self.PROGRAM_BLOCKED
        create = asyncio.create_subprocess_exec(*args, loop=self.loop)
        proc = self.loop.run_until_complete(create)
        proc.kill()
        returncode = self.loop.run_until_complete(proc.wait())
        self.assertEqual(-signal.SIGKILL, returncode)

    def test_terminate(self):
        args = self.PROGRAM_BLOCKED
        create = asyncio.create_subprocess_exec(*args, loop=self.loop)
        proc = self.loop.run_until_complete(create)
        proc.terminate()
        returncode = self.loop.run_until_complete(proc.wait())
        self.assertEqual(-signal.SIGTERM, returncode)

    def test_send_signal(self):
        code = 'import time; print("sleeping", flush=True); time.sleep(3600)'
        args = [sys.executable, b'-W', b'ignore', b'-c', code]
        create = asyncio.create_subprocess_exec(*args,
                                                stdout=subprocess.PIPE,
                                                loop=self.loop)
        proc = self.loop.run_until_complete(create)

        @asyncio.coroutine
        def send_signal(proc):
            # basic synchronization to wait until the program is sleeping
            line = yield from proc.stdout.readline()
            self.assertEqual(line, b'sleeping\n')

            proc.send_signal(signal.SIGHUP)
            returncode = (yield from proc.wait())
            return returncode

        returncode = self.loop.run_until_complete(send_signal(proc))
        self.assertEqual(-signal.SIGHUP, returncode)

    def test_cancel_process_wait(self):
        # Issue #23140: cancel Process.wait()

        @asyncio.coroutine
        def cancel_wait():
            proc = yield from asyncio.create_subprocess_exec(
                *self.PROGRAM_BLOCKED,
                loop=self.loop)

            # Create an internal future waiting on the process exit
            task = self.loop.create_task(proc.wait())
            self.loop.call_soon(task.cancel)
            try:
                yield from task
            except asyncio.CancelledError:
                pass

            # Cancel the future
            task.cancel()

            # Kill the process and wait until it is done
            proc.kill()
            yield from proc.wait()

        self.loop.run_until_complete(cancel_wait())

    def test_cancel_make_subprocess_transport_exec(self):
        @asyncio.coroutine
        def cancel_make_transport():
            coro = asyncio.create_subprocess_exec(*self.PROGRAM_BLOCKED,
                                                  loop=self.loop)
            task = self.loop.create_task(coro)

            self.loop.call_soon(task.cancel)
            try:
                yield from task
            except asyncio.CancelledError:
                pass

            # Give the process handler some time to close itself
            yield from asyncio.sleep(0.3, loop=self.loop)
            gc.collect()

        # ignore the log:
        # "Exception during subprocess creation, kill the subprocess"
        with tb.disable_logger():
            self.loop.run_until_complete(cancel_make_transport())

    def test_cancel_post_init(self):
        @asyncio.coroutine
        def cancel_make_transport():
            coro = self.loop.subprocess_exec(asyncio.SubprocessProtocol,
                                             *self.PROGRAM_BLOCKED)
            task = self.loop.create_task(coro)

            self.loop.call_soon(task.cancel)
            try:
                yield from task
            except asyncio.CancelledError:
                pass

            # Give the process handler some time to close itself
            yield from asyncio.sleep(0.3, loop=self.loop)
            gc.collect()

        # ignore the log:
        # "Exception during subprocess creation, kill the subprocess"
        with tb.disable_logger():
            self.loop.run_until_complete(cancel_make_transport())
            tb.run_briefly(self.loop)

    def test_close_gets_process_closed(self):

        loop = self.loop

        class Protocol(asyncio.SubprocessProtocol):

            def __init__(self):
                self.closed = loop.create_future()

            def connection_lost(self, exc):
                self.closed.set_result(1)

        @asyncio.coroutine
        def test_subprocess():
            transport, protocol = yield from loop.subprocess_exec(
                Protocol, *self.PROGRAM_BLOCKED)
            pid = transport.get_pid()
            transport.close()
            self.assertIsNone(transport.get_returncode())
            yield from protocol.closed
            self.assertIsNotNone(transport.get_returncode())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

        loop.run_until_complete(test_subprocess())


class Test_UV_Process(_TestProcess, tb.UVTestCase):

    def test_process_streams_redirect(self):
        # This won't work for asyncio implementation of subprocess

        async def test():
            prog = bR'''
import sys
print('out', flush=True)
print('err', file=sys.stderr, flush=True)
            '''

            proc = await asyncio.create_subprocess_exec(
                sys.executable, b'-W', b'ignore', b'-c', prog,
                loop=self.loop)

            out, err = await proc.communicate()
            self.assertIsNone(out)
            self.assertIsNone(err)

        with tempfile.NamedTemporaryFile('w') as stdout:
            with tempfile.NamedTemporaryFile('w') as stderr:
                with contextlib.redirect_stdout(stdout):
                    with contextlib.redirect_stderr(stderr):
                        self.loop.run_until_complete(test())

                stdout.flush()
                stderr.flush()

                with open(stdout.name, 'rb') as so:
                    self.assertEqual(so.read(), b'out\n')

                with open(stderr.name, 'rb') as se:
                    self.assertEqual(se.read(), b'err\n')


class Test_AIO_Process(_TestProcess, tb.AIOTestCase):
    pass


class TestAsyncio_UV_Process(_AsyncioTests, tb.UVTestCase):
    pass


class TestAsyncio_AIO_Process(_AsyncioTests, tb.AIOTestCase):
    pass


class Test_UV_Process_Delayed(tb.UVTestCase):

    class TestProto:
        def __init__(self):
            self.lost = 0
            self.stages = []

        def connection_made(self, transport):
            self.stages.append(('CM', transport))

        def pipe_data_received(self, fd, data):
            if fd == 1:
                self.stages.append(('STDOUT', data))

        def pipe_connection_lost(self, fd, exc):
            if fd == 1:
                self.stages.append(('STDOUT', 'LOST'))

        def process_exited(self):
            self.stages.append('PROC_EXIT')

        def connection_lost(self, exc):
            self.stages.append(('CL', self.lost, exc))
            self.lost += 1

    async def run_sub(self, **kwargs):
        return await self.loop.subprocess_shell(
            lambda: self.TestProto(),
            'echo 1',
            **kwargs)

    def test_process_delayed_stdio__paused__stdin_pipe(self):
        transport, proto = self.loop.run_until_complete(
            self.run_sub(
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                __uvloop_sleep_after_fork=True))
        self.assertIsNot(transport, None)
        self.assertEqual(transport.get_returncode(), 0)
        self.assertEqual(
            set(proto.stages),
            {
                ('CM', transport),
                'PROC_EXIT',
                ('STDOUT', b'1\n'),
                ('STDOUT', 'LOST'),
                ('CL', 0, None)
            })

    def test_process_delayed_stdio__paused__no_stdin(self):
        transport, proto = self.loop.run_until_complete(
            self.run_sub(
                stdin=None,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                __uvloop_sleep_after_fork=True))
        self.assertIsNot(transport, None)
        self.assertEqual(transport.get_returncode(), 0)
        self.assertEqual(
            set(proto.stages),
            {
                ('CM', transport),
                'PROC_EXIT',
                ('STDOUT', b'1\n'),
                ('STDOUT', 'LOST'),
                ('CL', 0, None)
            })

    def test_process_delayed_stdio__not_paused__no_stdin(self):
        if os.environ.get('TRAVIS_OS_NAME') and sys.platform == 'darwin':
            # Randomly crashes on Travis, can't reproduce locally.
            raise unittest.SkipTest()

        transport, proto = self.loop.run_until_complete(
            self.run_sub(
                stdin=None,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE))
        self.loop.run_until_complete(transport._wait())
        self.assertEqual(transport.get_returncode(), 0)
        self.assertIsNot(transport, None)
        self.assertEqual(
            set(proto.stages),
            {
                ('CM', transport),
                'PROC_EXIT',
                ('STDOUT', b'1\n'),
                ('STDOUT', 'LOST'),
                ('CL', 0, None)
            })
