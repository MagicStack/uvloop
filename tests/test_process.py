import asyncio
import contextlib
import signal
import subprocess
import sys
import tempfile

from asyncio import test_utils
from uvloop import _testbase as tb


class _TestProcess:
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

    def test_process_executable_1(self):
        async def test():
            proc = await asyncio.create_subprocess_exec(
                b'doesnotexist', b'-c', b'print("spam")',
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
                cmd, b'-c', prog,
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
                cmd, b'-c', prog,
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
                cmd, b'-c', prog,
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
                sys.executable, '-c', prog,
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
                sys.executable, '-c', prog,
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
                    sys.executable, '-c', prog, '--',
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


class _AsyncioTests:

    # Program blocking
    PROGRAM_BLOCKED = [sys.executable, '-c', 'import time; time.sleep(3600)']

    # Program copying input to output
    PROGRAM_CAT = [
        sys.executable, '-c',
        ';'.join(('import sys',
                  'data = sys.stdin.buffer.read()',
                  'sys.stdout.buffer.write(data)'))]

    def test_stdin_not_inheritable(self):
        # asyncio issue #209: stdin must not be inheritable, otherwise
        # the Process.communicate() hangs
        @asyncio.coroutine
        def len_message(message):
            code = 'import sys; data = sys.stdin.read(); print(len(data))'
            proc = yield from asyncio.create_subprocess_exec(
                sys.executable, '-c', code,
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

    def test_stdin_stdout(self):
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
        args = [sys.executable, '-c', code]
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

        # ignore the log:
        # "Exception during subprocess creation, kill the subprocess"
        with test_utils.disable_logger():
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

        # ignore the log:
        # "Exception during subprocess creation, kill the subprocess"
        with test_utils.disable_logger():
            self.loop.run_until_complete(cancel_make_transport())
            test_utils.run_briefly(self.loop)


class Test_UV_Process(_TestProcess, tb.UVTestCase):

    def test_process_lated_stdio_init(self):

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

        async def run(**kwargs):
            return await self.loop.subprocess_shell(
                lambda: TestProto(),
                'echo 1',
                **kwargs)

        with self.subTest('paused, stdin pipe'):
            transport, proto = self.loop.run_until_complete(
                run(stdin=subprocess.PIPE,
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

        with self.subTest('paused, no stdin'):
            transport, proto = self.loop.run_until_complete(
                run(stdin=None,
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

        with self.subTest('no pause, no stdin'):
            transport, proto = self.loop.run_until_complete(
                run(stdin=None,
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

    def test_process_streams_redirect(self):
        # This won't work for asyncio implementation of subprocess

        async def test():
            prog = bR'''
import sys
print('out', flush=True)
print('err', file=sys.stderr, flush=True)
            '''

            proc = await asyncio.create_subprocess_exec(
                sys.executable, '-c', prog,
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
