import asyncio
import contextlib
import gc
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

import psutil

from uvloop import _testbase as tb


class _RedirectFD(contextlib.AbstractContextManager):
    def __init__(self, old_file, new_file):
        self._old_fd = old_file.fileno()
        self._old_fd_save = os.dup(self._old_fd)
        self._new_fd = new_file.fileno()

    def __enter__(self):
        os.dup2(self._new_fd, self._old_fd)

    def __exit__(self, exc_type, exc_val, exc_tb):
        os.dup2(self._old_fd_save, self._old_fd)
        os.close(self._old_fd_save)


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
                stderr=subprocess.PIPE)

            out, _ = await proc.communicate()
            self.assertEqual(out, b'spam\n')
            self.assertEqual(proc.returncode, 0)

        self.loop.run_until_complete(test())

    def test_process_env_2(self):
        async def test():
            cmd = 'env'
            env = {}  # empty environment
            proc = await asyncio.create_subprocess_exec(
                cmd,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE)

            out, _ = await proc.communicate()
            self.assertEqual(out, b'')
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
                stderr=subprocess.PIPE)

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
                stderr=subprocess.PIPE)

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
                preexec_fn=lambda: os.putenv("FRUIT", "apple"))

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
                preexec_fn=raise_it)

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
                stdout=subprocess.PIPE)

            out, err = await proc.communicate()
            self.assertEqual(out, b'spam\n')

        self.loop.run_until_complete(test())

    def test_process_executable_2(self):
        async def test():
            proc = await asyncio.create_subprocess_exec(
                pathlib.Path(sys.executable),
                b'-W', b'ignore', b'-c', b'print("spam")',
                stdout=subprocess.PIPE)

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
                stdout=subprocess.PIPE)

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
                stderr=subprocess.PIPE)

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
                stderr=subprocess.PIPE)

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
                stderr=subprocess.STDOUT)

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
                stderr=subprocess.DEVNULL)

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
                    pass_fds=(inherited.fileno(),))

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
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL)
                except FileNotFoundError:
                    pass
                await asyncio.sleep(0)

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
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL)
                finally:
                    await p.wait()
                await asyncio.sleep(0)

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
                    stdin=fd)

            with self.assertRaises(OSError):
                await asyncio.create_subprocess_exec(
                    'ls',
                    stdout=fd)

            with self.assertRaises(OSError):
                await asyncio.create_subprocess_exec(
                    'ls',
                    stderr=fd)

        self.loop.run_until_complete(main())

    def test_process_streams_redirect(self):
        async def test():
            prog = bR'''
import sys
print('out', flush=True)
print('err', file=sys.stderr, flush=True)
            '''

            proc = await asyncio.create_subprocess_exec(
                sys.executable, b'-W', b'ignore', b'-c', prog)

            out, err = await proc.communicate()
            self.assertIsNone(out)
            self.assertIsNone(err)

        with tempfile.NamedTemporaryFile('w') as stdout:
            with tempfile.NamedTemporaryFile('w') as stderr:
                with _RedirectFD(sys.stdout, stdout):
                    with _RedirectFD(sys.stderr, stderr):
                        self.loop.run_until_complete(test())

                stdout.flush()
                stderr.flush()

                with open(stdout.name, 'rb') as so:
                    self.assertEqual(so.read(), b'out\n')

                with open(stderr.name, 'rb') as se:
                    self.assertEqual(se.read(), b'err\n')


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
        async def len_message(message):
            code = 'import sys; data = sys.stdin.read(); print(len(data))'
            proc = await asyncio.create_subprocess_exec(
                sys.executable, b'-W', b'ignore', b'-c', code,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                close_fds=False)
            stdout, stderr = await proc.communicate(message)
            exitcode = await proc.wait()
            return (stdout, exitcode)

        output, exitcode = self.loop.run_until_complete(len_message(b'abc'))
        self.assertEqual(output.rstrip(), b'3')
        self.assertEqual(exitcode, 0)

    def test_stdin_stdout_pipe(self):
        args = self.PROGRAM_CAT

        async def run(data):
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE)

            # feed data
            proc.stdin.write(data)
            await proc.stdin.drain()
            proc.stdin.close()

            # get output and exitcode
            data = await proc.stdout.read()
            exitcode = await proc.wait()
            return (exitcode, data)

        task = run(b'some data')
        task = asyncio.wait_for(task, 60.0)
        exitcode, stdout = self.loop.run_until_complete(task)
        self.assertEqual(exitcode, 0)
        self.assertEqual(stdout, b'some data')

    def test_stdin_stdout_file(self):
        args = self.PROGRAM_CAT

        async def run(data, stdout):
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=subprocess.PIPE,
                stdout=stdout)

            # feed data
            proc.stdin.write(data)
            await proc.stdin.drain()
            proc.stdin.close()

            exitcode = await proc.wait()
            return exitcode

        with tempfile.TemporaryFile('w+b') as new_stdout:
            task = run(b'some data', new_stdout)
            task = asyncio.wait_for(task, 60.0)
            exitcode = self.loop.run_until_complete(task)
            self.assertEqual(exitcode, 0)

            new_stdout.seek(0)
            self.assertEqual(new_stdout.read(), b'some data')

    def test_stdin_stderr_file(self):
        args = self.PROGRAM_ERROR

        async def run(stderr):
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=subprocess.PIPE,
                stderr=stderr)

            exitcode = await proc.wait()
            return exitcode

        with tempfile.TemporaryFile('w+b') as new_stderr:
            task = run(new_stderr)
            task = asyncio.wait_for(task, 60.0)
            exitcode = self.loop.run_until_complete(task)
            self.assertEqual(exitcode, 1)

            new_stderr.seek(0)
            self.assertIn(b'ZeroDivisionError', new_stderr.read())

    def test_communicate(self):
        args = self.PROGRAM_CAT

        async def run(data):
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE)
            stdout, stderr = await proc.communicate(data)
            return proc.returncode, stdout

        task = run(b'some data')
        task = asyncio.wait_for(task, 60.0)
        exitcode, stdout = self.loop.run_until_complete(task)
        self.assertEqual(exitcode, 0)
        self.assertEqual(stdout, b'some data')

    def test_start_new_session(self):
        # start the new process in a new session
        create = asyncio.create_subprocess_shell('exit 8',
                                                 start_new_session=True)
        proc = self.loop.run_until_complete(create)
        exitcode = self.loop.run_until_complete(proc.wait())
        self.assertEqual(exitcode, 8)

    def test_shell(self):
        create = asyncio.create_subprocess_shell('exit 7')
        proc = self.loop.run_until_complete(create)
        exitcode = self.loop.run_until_complete(proc.wait())
        self.assertEqual(exitcode, 7)

    def test_kill(self):
        args = self.PROGRAM_BLOCKED
        create = asyncio.create_subprocess_exec(*args)
        proc = self.loop.run_until_complete(create)
        proc.kill()
        returncode = self.loop.run_until_complete(proc.wait())
        self.assertEqual(-signal.SIGKILL, returncode)

    def test_terminate(self):
        args = self.PROGRAM_BLOCKED
        create = asyncio.create_subprocess_exec(*args)
        proc = self.loop.run_until_complete(create)
        proc.terminate()
        returncode = self.loop.run_until_complete(proc.wait())
        self.assertEqual(-signal.SIGTERM, returncode)

    def test_send_signal(self):
        code = 'import time; print("sleeping", flush=True); time.sleep(3600)'
        args = [sys.executable, b'-W', b'ignore', b'-c', code]
        create = asyncio.create_subprocess_exec(*args,
                                                stdout=subprocess.PIPE)
        proc = self.loop.run_until_complete(create)

        async def send_signal(proc):
            # basic synchronization to wait until the program is sleeping
            line = await proc.stdout.readline()
            self.assertEqual(line, b'sleeping\n')

            proc.send_signal(signal.SIGHUP)
            returncode = (await proc.wait())
            return returncode

        returncode = self.loop.run_until_complete(send_signal(proc))
        self.assertEqual(-signal.SIGHUP, returncode)

    def test_cancel_process_wait(self):
        # Issue #23140: cancel Process.wait()

        async def cancel_wait():
            proc = await asyncio.create_subprocess_exec(
                *self.PROGRAM_BLOCKED)

            # Create an internal future waiting on the process exit
            task = self.loop.create_task(proc.wait())
            self.loop.call_soon(task.cancel)
            try:
                await task
            except asyncio.CancelledError:
                pass

            # Cancel the future
            task.cancel()

            # Kill the process and wait until it is done
            proc.kill()
            await proc.wait()

        self.loop.run_until_complete(cancel_wait())

    def test_cancel_make_subprocess_transport_exec(self):
        async def cancel_make_transport():
            coro = asyncio.create_subprocess_exec(*self.PROGRAM_BLOCKED)
            task = self.loop.create_task(coro)

            self.loop.call_soon(task.cancel)
            try:
                await task
            except asyncio.CancelledError:
                pass

            # Give the process handler some time to close itself
            await asyncio.sleep(0.3)
            gc.collect()

        # ignore the log:
        # "Exception during subprocess creation, kill the subprocess"
        with tb.disable_logger():
            self.loop.run_until_complete(cancel_make_transport())

    def test_cancel_post_init(self):
        async def cancel_make_transport():
            coro = self.loop.subprocess_exec(asyncio.SubprocessProtocol,
                                             *self.PROGRAM_BLOCKED)
            task = self.loop.create_task(coro)

            self.loop.call_soon(task.cancel)
            try:
                await task
            except asyncio.CancelledError:
                pass

            # Give the process handler some time to close itself
            await asyncio.sleep(0.3)
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

        async def test_subprocess():
            transport, protocol = await loop.subprocess_exec(
                Protocol, *self.PROGRAM_BLOCKED)
            pid = transport.get_pid()
            transport.close()
            self.assertIsNone(transport.get_returncode())
            await protocol.closed
            self.assertIsNotNone(transport.get_returncode())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

        loop.run_until_complete(test_subprocess())

    def test_communicate_large_stdout_65536(self):
        self._test_communicate_large_stdout(65536)

    def test_communicate_large_stdout_65537(self):
        self._test_communicate_large_stdout(65537)

    def test_communicate_large_stdout_1000000(self):
        self._test_communicate_large_stdout(1000000)

    def _test_communicate_large_stdout(self, size):
        async def copy_stdin_to_stdout(stdin):
            # See https://github.com/MagicStack/uvloop/issues/363
            # A program that copies stdin to stdout character by character
            code = ('import sys, shutil; '
                    'shutil.copyfileobj(sys.stdin, sys.stdout, 1)')
            proc = await asyncio.create_subprocess_exec(
                sys.executable, b'-W', b'ignore', b'-c', code,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE)
            stdout, _stderr = await asyncio.wait_for(proc.communicate(stdin),
                                                     60.0)
            return stdout

        stdin = b'x' * size
        stdout = self.loop.run_until_complete(copy_stdin_to_stdout(stdin))
        self.assertEqual(stdout, stdin)

    def test_write_huge_stdin_8192(self):
        self._test_write_huge_stdin(8192)

    def test_write_huge_stdin_8193(self):
        self._test_write_huge_stdin(8193)

    def test_write_huge_stdin_219263(self):
        self._test_write_huge_stdin(219263)

    def test_write_huge_stdin_219264(self):
        self._test_write_huge_stdin(219264)

    def _test_write_huge_stdin(self, buf_size):
        code = '''
import sys
n = 0
while True:
    line = sys.stdin.readline()
    if not line:
        print("unexpected EOF", file=sys.stderr)
        break
    if line == "END\\n":
        break
    n+=1
print(n)'''
        num_lines = buf_size - len(b"END\n")
        args = [sys.executable, b'-W', b'ignore', b'-c', code]

        async def test():
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE,
                stdin=asyncio.subprocess.PIPE)
            data = b"\n" * num_lines + b"END\n"
            self.assertEqual(len(data), buf_size)
            proc.stdin.write(data)
            await asyncio.wait_for(proc.stdin.drain(), timeout=5.0)
            try:
                await asyncio.wait_for(proc.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                proc.kill()
                proc.stdin.close()
                await proc.wait()
                raise
            out = await proc.stdout.read()
            self.assertEqual(int(out), num_lines)

        self.loop.run_until_complete(test())


class Test_UV_Process(_TestProcess, tb.UVTestCase):
    def test_process_double_close(self):
        script = textwrap.dedent("""
            import os
            import sys
            from unittest import mock

            import asyncio

            pipes = []
            original_os_pipe = os.pipe
            def log_pipes():
                pipe = original_os_pipe()
                pipes.append(pipe)
                return pipe

            dups = []
            original_os_dup = os.dup
            def log_dups(*args, **kwargs):
                dup = original_os_dup(*args, **kwargs)
                dups.append(dup)
                return dup

            with mock.patch(
                "os.close", wraps=os.close
            ) as os_close, mock.patch(
                "os.pipe", new=log_pipes
            ), mock.patch(
                "os.dup", new=log_dups
            ):
                import uvloop


            async def test():
                proc = await asyncio.create_subprocess_exec(
                    sys.executable, "-c", "pass"
                )
                await proc.communicate()

            uvloop.run(test())

            stdin, stdout, stderr = dups
            (r, w), = pipes
            assert os_close.mock_calls == [
                mock.call(w),
                mock.call(r),
                mock.call(stderr),
                mock.call(stdout),
                mock.call(stdin),
            ]
        """)
        subprocess.run([sys.executable, '-c', script], check=True)


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
                uvloop_sleep_after_fork=True))
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
                uvloop_sleep_after_fork=True))
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
        if ((os.environ.get('TRAVIS_OS_NAME')
                or os.environ.get('GITHUB_WORKFLOW'))
                and sys.platform == 'darwin'):
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
