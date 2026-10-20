import asyncio
import concurrent.futures
import os
import pathlib
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest

from uvloop import _testbase as tb


def patched_getaddrinfo(*args, **kwargs):
    # corrected socket.getaddrinfo() behavior: ai_canonname always follows the
    # flag AI_CANONNAME, even if `host` is an IP
    rv = []
    result = socket.getaddrinfo(*args, **kwargs)
    first = True
    for af, sk, proto, canon_name, addr in result:
        if kwargs.get('flags', 0) & socket.AI_CANONNAME:
            if not canon_name and first:
                first = False
                canon_name = args[0]
                if not isinstance(canon_name, str):
                    canon_name = canon_name.decode('ascii')
        elif canon_name:
            canon_name = ''
        rv.append((af, sk, proto, canon_name, addr))
    return rv


class BaseTestDNS:

    def _test_getaddrinfo(self, *args, _patch=False, _sorted=False, **kwargs):
        err = None
        try:
            if _patch:
                a1 = patched_getaddrinfo(*args, **kwargs)
            else:
                a1 = socket.getaddrinfo(*args, **kwargs)
        except (socket.gaierror, UnicodeError) as ex:
            err = ex

        try:
            a2 = self.loop.run_until_complete(
                self.loop.getaddrinfo(*args, **kwargs))
        except (socket.gaierror, UnicodeError) as ex:
            if err is not None:
                self.assertEqual(ex.args, err.args)
            else:
                ex.__context__ = err
                raise ex
        except OSError as ex:
            ex.__context__ = err
            raise ex
        else:
            if err is not None:
                raise err

            if _sorted:
                if kwargs.get('flags', 0) & socket.AI_CANONNAME and a1 and a2:
                    # The API doesn't guarantee the ai_canonname value if
                    # multiple results are returned, but both implementations
                    # must return the same value for the first result.
                    self.assertEqual(a1[0][3], a2[0][3])
                    a1 = [(af, sk, pr, addr) for af, sk, pr, _, addr in a1]
                    a2 = [(af, sk, pr, addr) for af, sk, pr, _, addr in a2]

                self.assertEqual(sorted(a1), sorted(a2))
            else:
                self.assertEqual(a1, a2)

    def _test_getnameinfo(self, *args, **kwargs):
        err = None
        try:
            a1 = socket.getnameinfo(*args, **kwargs)
        except Exception as ex:
            err = ex

        try:
            a2 = self.loop.run_until_complete(
                self.loop.getnameinfo(*args, **kwargs))
        except Exception as ex:
            if err is not None:
                if ex.__class__ is not err.__class__:
                    print(ex, err)
                self.assertIs(ex.__class__, err.__class__)
                self.assertEqual(ex.args, err.args)
            else:
                raise
        else:
            if err is not None:
                raise err

            self.assertEqual(a1, a2)

    def test_getaddrinfo_1(self):
        self._test_getaddrinfo('example.com', 80, _sorted=True)
        self._test_getaddrinfo('example.com', 80, type=socket.SOCK_STREAM,
                               _sorted=True)

    def test_getaddrinfo_2(self):
        self._test_getaddrinfo('example.com', 80, flags=socket.AI_CANONNAME,
                               _sorted=True)

    def test_getaddrinfo_3(self):
        self._test_getaddrinfo('a' + '1' * 50 + '.wat', 800)

    def test_getaddrinfo_4(self):
        self._test_getaddrinfo('example.com', 80, family=-1)
        self._test_getaddrinfo('example.com', 80, type=socket.SOCK_STREAM,
                               family=-1)

    def test_getaddrinfo_5(self):
        self._test_getaddrinfo('example.com', '80', _sorted=True)
        self._test_getaddrinfo('example.com', '80', type=socket.SOCK_STREAM,
                               _sorted=True)

    def test_getaddrinfo_6(self):
        self._test_getaddrinfo(b'example.com', b'80', _sorted=True)
        self._test_getaddrinfo(b'example.com', b'80', type=socket.SOCK_STREAM,
                               _sorted=True)

    def test_getaddrinfo_7(self):
        self._test_getaddrinfo(None, 0)
        self._test_getaddrinfo(None, 0, type=socket.SOCK_STREAM)

    def test_getaddrinfo_8(self):
        self._test_getaddrinfo('', 0)
        self._test_getaddrinfo('', 0, type=socket.SOCK_STREAM)

    def test_getaddrinfo_9(self):
        self._test_getaddrinfo(b'', 0)
        self._test_getaddrinfo(b'', 0, type=socket.SOCK_STREAM)

    def test_getaddrinfo_10(self):
        self._test_getaddrinfo(None, None)
        self._test_getaddrinfo(None, None, type=socket.SOCK_STREAM)

    def test_getaddrinfo_11(self):
        self._test_getaddrinfo(b'example.com', '80', _sorted=True)
        self._test_getaddrinfo(b'example.com', '80', type=socket.SOCK_STREAM,
                               _sorted=True)

    def test_getaddrinfo_12(self):
        # musl always returns ai_canonname but we don't
        patch = self.implementation != 'asyncio'

        self._test_getaddrinfo('127.0.0.1', '80')
        self._test_getaddrinfo('127.0.0.1', '80', type=socket.SOCK_STREAM,
                               _patch=patch)

    def test_getaddrinfo_13(self):
        # musl always returns ai_canonname but we don't
        patch = self.implementation != 'asyncio'

        self._test_getaddrinfo(b'127.0.0.1', b'80')
        self._test_getaddrinfo(b'127.0.0.1', b'80', type=socket.SOCK_STREAM,
                               _patch=patch)

    def test_getaddrinfo_14(self):
        # musl always returns ai_canonname but we don't
        patch = self.implementation != 'asyncio'

        self._test_getaddrinfo(b'127.0.0.1', b'http')
        self._test_getaddrinfo(b'127.0.0.1', b'http', type=socket.SOCK_STREAM,
                               _patch=patch)

    def test_getaddrinfo_15(self):
        # musl always returns ai_canonname but we don't
        patch = self.implementation != 'asyncio'

        self._test_getaddrinfo('127.0.0.1', 'http')
        self._test_getaddrinfo('127.0.0.1', 'http', type=socket.SOCK_STREAM,
                               _patch=patch)

    def test_getaddrinfo_16(self):
        self._test_getaddrinfo('localhost', 'http')
        self._test_getaddrinfo('localhost', 'http', type=socket.SOCK_STREAM)

    def test_getaddrinfo_17(self):
        self._test_getaddrinfo(b'localhost', 'http')
        self._test_getaddrinfo(b'localhost', 'http', type=socket.SOCK_STREAM)

    def test_getaddrinfo_18(self):
        self._test_getaddrinfo('localhost', b'http')
        self._test_getaddrinfo('localhost', b'http', type=socket.SOCK_STREAM)

    def test_getaddrinfo_19(self):
        # musl always returns ai_canonname while macOS never return for IPs,
        # but we strictly follow the docs to use the AI_CANONNAME flag in a
        # shortcut __static_getaddrinfo_pyaddr()
        patch = self.implementation != 'asyncio'

        self._test_getaddrinfo('::1', 80)
        self._test_getaddrinfo('::1', 80, type=socket.SOCK_STREAM,
                               _patch=patch)
        self._test_getaddrinfo('::1', 80, type=socket.SOCK_STREAM,
                               flags=socket.AI_CANONNAME, _patch=patch)

    def test_getaddrinfo_20(self):
        # musl always returns ai_canonname while macOS never return for IPs,
        # but we strictly follow the docs to use the AI_CANONNAME flag in a
        # shortcut __static_getaddrinfo_pyaddr()
        patch = self.implementation != 'asyncio'

        self._test_getaddrinfo('127.0.0.1', 80)
        self._test_getaddrinfo('127.0.0.1', 80, type=socket.SOCK_STREAM,
                               _patch=patch)
        self._test_getaddrinfo('127.0.0.1', 80, type=socket.SOCK_STREAM,
                               flags=socket.AI_CANONNAME, _patch=patch)

    # https://github.com/libuv/libuv/security/advisories/GHSA-f74f-cvh7-c6q6
    # See also: https://github.com/MagicStack/uvloop/pull/600
    def test_getaddrinfo_21(self):
        payload = f'0x{"0" * 246}7f000001.example.com'.encode('ascii')
        self._test_getaddrinfo(payload, 80)
        self._test_getaddrinfo(payload, 80, type=socket.SOCK_STREAM)

    def test_getaddrinfo_22(self):
        payload = f'0x{"0" * 246}7f000001.example.com'
        self._test_getaddrinfo(payload, 80)
        self._test_getaddrinfo(payload, 80, type=socket.SOCK_STREAM)

    def test_getaddrinfo_broadcast(self):
        self._test_getaddrinfo('<broadcast>', 80)
        self._test_getaddrinfo('<broadcast>', 80, type=socket.SOCK_STREAM)

    ######

    def test_getnameinfo_1(self):
        self._test_getnameinfo(('127.0.0.1', 80), 0)

    def test_getnameinfo_2(self):
        self._test_getnameinfo(('127.0.0.1', 80, 1231231231213), 0)

    def test_getnameinfo_3(self):
        self._test_getnameinfo(('127.0.0.1', 80, 0, 0), 0)

    def test_getnameinfo_4(self):
        self._test_getnameinfo(('::1', 80), 0)

    def test_getnameinfo_5(self):
        self._test_getnameinfo(('localhost', 8080), 0)


class Test_UV_DNS(BaseTestDNS, tb.UVTestCase):

    def test_getaddrinfo_with_busy_default_executor(self):
        started = threading.Event()
        release = threading.Event()

        def application_work():
            started.set()
            release.wait(10)

        executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.loop.set_default_executor(executor)
        work = executor.submit(application_work)
        try:
            self.assertTrue(started.wait(5))
            result = self.loop.run_until_complete(asyncio.wait_for(
                self.loop.getaddrinfo('localhost', 443,
                                      family=socket.AF_INET,
                                      type=socket.SOCK_STREAM), 5))
            self.assertTrue(result)
            self.assertFalse(work.done())
        finally:
            release.set()
            executor.shutdown(wait=True)

    def test_getaddrinfo_close_loop(self):
        # Test that we can close the loop with a running
        # DNS query.

        try:
            # Check that we have internet connection
            socket.getaddrinfo('example.com', 80)
        except socket.error:
            raise unittest.SkipTest

        async def run():
            fut = self.loop.create_task(
                self.loop.getaddrinfo('example.com', 80))
            await asyncio.sleep(0)
            fut.cancel()
            self.loop.stop()

        try:
            self.loop.run_until_complete(run())
        finally:
            self.loop.close()


class Test_AIO_DNS(BaseTestDNS, tb.AIOTestCase):
    pass


@unittest.skipUnless(sys.platform == 'linux', 'requires LD_PRELOAD')
class TestDNSClose(unittest.TestCase):
    # Regression for MagicStack/uvloop#777.
    # Block only our test hostname, without consulting the network. The worker
    # signals that it has started, then waits until the parent releases it.
    SHIM = r"""
        #define _GNU_SOURCE
        #include <dlfcn.h>
        #include <errno.h>
        #include <netdb.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        static struct addrinfo *completed_result;

        static void notify(char byte) {
            int started = atoi(getenv("DNS_STARTED_FD"));
            ssize_t n;
            do {
                n = write(started, &byte, 1);
            } while (n < 0 && errno == EINTR);
            if (n != 1)
                _exit(90);
        }

        static void wait_for_release(void) {
            int release = atoi(getenv("DNS_RELEASE_FD"));
            char byte;
            ssize_t n;
            notify('S');
            do {
                n = read(release, &byte, 1);
            } while (n < 0 && errno == EINTR);
        }

        int getnameinfo(const struct sockaddr *addr, socklen_t addrlen,
                        char *host, socklen_t hostlen,
                        char *service, socklen_t servicelen, int flags) {
            int (*real_getnameinfo)(const struct sockaddr *, socklen_t,
                                   char *, socklen_t, char *, socklen_t, int) =
                dlsym(RTLD_NEXT, "getnameinfo");
            if (getenv("DNS_BLOCK_REVERSE")) {
                wait_for_release();
                if (!getenv("DNS_SUCCESS"))
                    return EAI_NONAME;
            }
            return real_getnameinfo(addr, addrlen, host, hostlen,
                                    service, servicelen, flags);
        }

        int getaddrinfo(const char *node, const char *service,
                        const struct addrinfo *hints, struct addrinfo **res) {
            int (*real_getaddrinfo)(const char *, const char *,
                                    const struct addrinfo *,
                                    struct addrinfo **) =
                dlsym(RTLD_NEXT, "getaddrinfo");
            if (node && strcmp(node, "uvloop-close-test.invalid") == 0) {
                wait_for_release();
                if (getenv("DNS_SUCCESS")) {
                    int err = real_getaddrinfo("127.0.0.1", service,
                                               hints, res);
                    if (err == 0)
                        completed_result = *res;
                    return err;
                }
                return EAI_NONAME;
            }
            return real_getaddrinfo(node, service, hints, res);
        }

        void freeaddrinfo(struct addrinfo *res) {
            void (*real_freeaddrinfo)(struct addrinfo *) =
                dlsym(RTLD_NEXT, "freeaddrinfo");
            if (res && res == completed_result) {
                completed_result = NULL;
                notify('F');
            }
            real_freeaddrinfo(res);
        }
    """

    CHILD = """
        import asyncio
        import concurrent.futures
        import gc
        import os
        import sys
        import weakref

        if sys.argv[1] == 'uvloop':
            import uvloop
            loop = uvloop.new_event_loop()
        else:
            loop = asyncio.new_event_loop()

        executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        loop.set_default_executor(executor)
        started = int(sys.argv[2])
        os.set_blocking(started, False)

        expected_started = int(os.environ.get('DNS_STARTED_COUNT', '1'))
        drop_loop = bool(os.environ.get('DNS_DROP_LOOP'))

        async def wait_for_dns():
            count = 0
            while True:
                try:
                    byte = os.read(started, 1)
                    if byte != b'S':
                        raise RuntimeError('DNS worker handshake failed')
                    count += 1
                    if count == expected_started:
                        return
                except BlockingIOError:
                    await asyncio.sleep(0.01)

        def query():
            if sys.argv[4] == 'reverse':
                return loop.getnameinfo(('127.0.0.1', 443))
            return loop.getaddrinfo('uvloop-close-test.invalid', 443)

        tasks = [loop.create_task(query())
                 for _ in range(int(os.environ.get('DNS_REQUESTS', '1')))]
        loop.run_until_complete(asyncio.wait_for(wait_for_dns(), 5))
        assert all(not task.done() for task in tasks)
        if drop_loop:
            for task in tasks:
                task.cancel()
            loop.run_until_complete(asyncio.gather(
                *tasks, return_exceptions=True))
            del task
        if int(os.environ.get('DNS_REQUESTS', '1')) > expected_started:
            # Both libuv DNS workers are blocked. A second loop's DNS is
            # therefore entirely queued, and should close without a thread.
            other = uvloop.new_event_loop()
            queued = other.create_task(other.getaddrinfo(
                'uvloop-close-test.invalid', 443))
            other.run_until_complete(asyncio.sleep(0))
            queued.cancel()
            other.run_until_complete(asyncio.gather(
                queued, return_exceptions=True))
            other.close()
            assert other._closed_loop_thread is None
        print('CLOSE_ENTER', flush=True)
        loop.close()
        loop.close()  # Idempotent even while native cleanup is pending.
        timestamp = loop.time()
        assert loop.time() >= timestamp
        print('CLOSE_RETURN', flush=True)
        cleanup = (loop._closed_loop_thread
                   if sys.argv[1] == 'uvloop' else None)
        if drop_loop:
            ref = weakref.ref(loop)
            tasks.clear()
            del loop
            gc.collect()
            assert ref() is not None, 'native work lost its loop owner'
        os.write(int(sys.argv[3]), b'C')
        if sys.argv[1] == 'asyncio' and sys.version_info < (3, 10):
            # Python 3.9's executor bridge delivers to closed loops. This
            # control checks close() only; uvloop always checks completion.
            os._exit(0)
        # The parent releases DNS only after close() returns. Wait for the
        # worker and its completion callback to catch late-delivery errors.
        executor.shutdown(wait=True)
        if sys.argv[1] == 'uvloop':
            if cleanup is not None:
                cleanup.join(5)
                assert not cleanup.is_alive(), 'native cleanup did not finish'
            if drop_loop:
                gc.collect()
                assert ref() is None, 'closed loop leaked after native cleanup'
            if os.environ.get('DNS_SUCCESS') and sys.argv[4] != 'reverse':
                assert os.read(started, 1) == b'F', 'DNS result was not freed'
            if int(os.environ.get('DNS_REQUESTS', '1')) > expected_started:
                try:
                    os.read(started, 1)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError('queued DNS work was not cancelled')
            print('CLEANUP_RETURN', flush=True)
        # Avoid pending-task diagnostics during interpreter shutdown.
        os._exit(0)
    """

    @classmethod
    def setUpClass(cls):
        cc = shutil.which('cc')
        if cc is None:
            raise unittest.SkipTest('C compiler required for DNS shim')
        tmp = tempfile.TemporaryDirectory(prefix='uvloop-dns-close-')
        cls.addClassCleanup(tmp.cleanup)
        source = pathlib.Path(tmp.name) / 'dns.c'
        cls.shim = pathlib.Path(tmp.name) / 'dns.so'
        source.write_text(textwrap.dedent(cls.SHIM))
        subprocess.run(
            [cc, '-shared', '-fPIC', '-Wall', '-Werror', str(source),
             '-o', str(cls.shim), '-ldl'],
            check=True, capture_output=True, text=True, timeout=30)

    def check_close(self, implementation, reverse=False, *,
                    success=False, queued=False, drop_loop=False):
        started_read, started_write = os.pipe()
        release_read, release_write = os.pipe()
        closed_read, closed_write = os.pipe()
        try:
            env = dict(os.environ,
                       DNS_STARTED_FD=str(started_write),
                       DNS_RELEASE_FD=str(release_read))
            env['LD_PRELOAD'] = str(self.shim)
            env.pop('DNS_BLOCK_REVERSE', None)
            env.pop('DNS_SUCCESS', None)
            env.pop('DNS_DROP_LOOP', None)
            env['UV_THREADPOOL_SIZE'] = '4'
            env['DNS_REQUESTS'] = '3' if queued else '1'
            env['DNS_STARTED_COUNT'] = '2' if queued else '1'
            if success:
                env['DNS_SUCCESS'] = '1'
            if drop_loop:
                env['DNS_DROP_LOOP'] = '1'
            if reverse:
                env['DNS_BLOCK_REVERSE'] = '1'
            with subprocess.Popen(
                [sys.executable, '-c', textwrap.dedent(self.CHILD),
                 implementation, str(started_read), str(closed_write),
                 'reverse' if reverse else 'forward'],
                env=env,
                pass_fds=(started_read, started_write, release_read,
                          closed_write),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ) as proc:
                try:
                    ready, _, _ = select.select([closed_read], [], [], 10)
                    if not ready:
                        raise subprocess.TimeoutExpired(proc.args, 10)
                    self.assertEqual(os.read(closed_read, 1), b'C')
                    os.write(release_write, b'RR' if queued else b'R')
                    stdout, stderr = proc.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    stdout, stderr = proc.communicate()
                    self.assertIn('CLOSE_ENTER', stdout, (stdout, stderr))
                    self.fail(
                        'DNS shutdown or late completion timed out '
                        f'request ({implementation})\n{stdout}{stderr}')
                self.assertEqual(proc.returncode, 0, (stdout, stderr))
                self.assertIn('CLOSE_RETURN', stdout)
                if implementation == 'uvloop':
                    self.assertIn('CLEANUP_RETURN', stdout)
                self.assertEqual(stderr, '')
        finally:
            # Close every pipe, including when the watchdog kills the child.
            for fd in (started_read, started_write,
                       release_read, release_write,
                       closed_read, closed_write):
                os.close(fd)

    def test_uvloop_close_during_getaddrinfo(self):
        self.check_close('uvloop')

    def test_asyncio_close_during_getaddrinfo(self):
        self.check_close('asyncio')

    def test_uvloop_close_during_getnameinfo(self):
        self.check_close('uvloop', reverse=True)

    @unittest.skipIf(
        sys.version_info < (3, 11),
        'stdlib getnameinfo holds the GIL before Python 3.11')
    def test_asyncio_close_during_getnameinfo(self):
        self.check_close('asyncio', reverse=True)

    def test_uvloop_close_before_successful_getaddrinfo(self):
        self.check_close('uvloop', success=True)

    def test_uvloop_close_before_successful_getnameinfo(self):
        self.check_close('uvloop', reverse=True, success=True)

    def test_uvloop_close_cancels_queued_dns(self):
        self.check_close('uvloop', queued=True)

    def test_uvloop_close_retains_loop_until_dns_finishes(self):
        self.check_close('uvloop', drop_loop=True)

    def test_uvloop_close_retains_loop_until_reverse_dns_finishes(self):
        self.check_close('uvloop', reverse=True, drop_loop=True)
