import asyncio
import contextvars
import decimal
import itertools
import random
import socket
import ssl
import sys
import tempfile
import unittest
import weakref

from uvloop import _testbase as tb


class _BaseProtocol(asyncio.BaseProtocol):
    def __init__(self, cvar, *, loop=None):
        self.cvar = cvar
        self.transport = None
        self.connection_made_fut = asyncio.Future(loop=loop)
        self.buffered_ctx = None
        self.data_received_fut = asyncio.Future(loop=loop)
        self.eof_received_fut = asyncio.Future(loop=loop)
        self.pause_writing_fut = asyncio.Future(loop=loop)
        self.resume_writing_fut = asyncio.Future(loop=loop)
        self.pipe_ctx = {0, 1, 2}
        self.pipe_connection_lost_fut = asyncio.Future(loop=loop)
        self.process_exited_fut = asyncio.Future(loop=loop)
        self.error_received_fut = asyncio.Future(loop=loop)
        self.connection_lost_ctx = None
        self.done = asyncio.Future(loop=loop)

    def connection_made(self, transport):
        self.transport = transport
        self.connection_made_fut.set_result(self.cvar.get())

    def connection_lost(self, exc):
        self.connection_lost_ctx = self.cvar.get()
        if exc is None:
            self.done.set_result(None)
        else:
            self.done.set_exception(exc)

    def eof_received(self):
        self.eof_received_fut.set_result(self.cvar.get())

    def pause_writing(self):
        self.pause_writing_fut.set_result(self.cvar.get())

    def resume_writing(self):
        self.resume_writing_fut.set_result(self.cvar.get())


class _Protocol(_BaseProtocol, asyncio.Protocol):
    def data_received(self, data):
        self.data_received_fut.set_result(self.cvar.get())


class _BufferedProtocol(_BaseProtocol, asyncio.BufferedProtocol):
    def get_buffer(self, sizehint):
        if self.buffered_ctx is None:
            self.buffered_ctx = self.cvar.get()
        elif self.cvar.get() != self.buffered_ctx:
            self.data_received_fut.set_exception(ValueError("{} != {}".format(
                self.buffered_ctx, self.cvar.get(),
            )))
        return bytearray(65536)

    def buffer_updated(self, nbytes):
        if not self.data_received_fut.done():
            if self.cvar.get() == self.buffered_ctx:
                self.data_received_fut.set_result(self.cvar.get())
            else:
                self.data_received_fut.set_exception(
                    ValueError("{} != {}".format(
                        self.buffered_ctx, self.cvar.get(),
                    ))
                )


class _DatagramProtocol(_BaseProtocol, asyncio.DatagramProtocol):
    def datagram_received(self, data, addr):
        self.data_received_fut.set_result(self.cvar.get())

    def error_received(self, exc):
        self.error_received_fut.set_result(self.cvar.get())


class _SubprocessProtocol(_BaseProtocol, asyncio.SubprocessProtocol):
    def pipe_data_received(self, fd, data):
        self.data_received_fut.set_result(self.cvar.get())

    def pipe_connection_lost(self, fd, exc):
        self.pipe_ctx.remove(fd)
        val = self.cvar.get()
        self.pipe_ctx.add(val)
        if not any(isinstance(x, int) for x in self.pipe_ctx):
            if len(self.pipe_ctx) == 1:
                self.pipe_connection_lost_fut.set_result(val)
            else:
                self.pipe_connection_lost_fut.set_exception(
                    AssertionError(str(list(self.pipe_ctx))))

    def process_exited(self):
        self.process_exited_fut.set_result(self.cvar.get())


class _SSLSocketOverSSL:
    # because wrap_socket() doesn't work correctly on
    # SSLSocket, we have to do the 2nd level SSL manually

    def __init__(self, ssl_sock, ctx, **kwargs):
        self.sock = ssl_sock
        self.incoming = ssl.MemoryBIO()
        self.outgoing = ssl.MemoryBIO()
        self.sslobj = ctx.wrap_bio(
            self.incoming, self.outgoing, **kwargs)
        self.do(self.sslobj.do_handshake)

    def do(self, func, *args):
        while True:
            try:
                rv = func(*args)
                break
            except ssl.SSLWantReadError:
                if self.outgoing.pending:
                    self.sock.send(self.outgoing.read())
                self.incoming.write(self.sock.recv(65536))
        if self.outgoing.pending:
            self.sock.send(self.outgoing.read())
        return rv

    def send(self, data):
        self.do(self.sslobj.write, data)

    def unwrap(self):
        self.do(self.sslobj.unwrap)

    def close(self):
        self.sock.unwrap()
        self.sock.close()


class _ContextBaseTests(tb.SSLTestCase):

    ONLYCERT = tb._cert_fullname(__file__, 'ssl_cert.pem')
    ONLYKEY = tb._cert_fullname(__file__, 'ssl_key.pem')

    def test_task_decimal_context(self):
        async def fractions(t, precision, x, y):
            with decimal.localcontext() as ctx:
                ctx.prec = precision
                a = decimal.Decimal(x) / decimal.Decimal(y)
                await asyncio.sleep(t)
                b = decimal.Decimal(x) / decimal.Decimal(y ** 2)
                return a, b

        async def main():
            r1, r2 = await asyncio.gather(
                fractions(0.1, 3, 1, 3), fractions(0.2, 6, 1, 3))

            return r1, r2

        r1, r2 = self.loop.run_until_complete(main())

        self.assertEqual(str(r1[0]), '0.333')
        self.assertEqual(str(r1[1]), '0.111')

        self.assertEqual(str(r2[0]), '0.333333')
        self.assertEqual(str(r2[1]), '0.111111')

    def test_task_context_1(self):
        cvar = contextvars.ContextVar('cvar', default='nope')

        async def sub():
            await asyncio.sleep(0.01)
            self.assertEqual(cvar.get(), 'nope')
            cvar.set('something else')

        async def main():
            self.assertEqual(cvar.get(), 'nope')
            subtask = self.loop.create_task(sub())
            cvar.set('yes')
            self.assertEqual(cvar.get(), 'yes')
            await subtask
            self.assertEqual(cvar.get(), 'yes')

        task = self.loop.create_task(main())
        self.loop.run_until_complete(task)

    def test_task_context_2(self):
        cvar = contextvars.ContextVar('cvar', default='nope')

        async def main():
            def fut_on_done(fut):
                # This change must not pollute the context
                # of the "main()" task.
                cvar.set('something else')

            self.assertEqual(cvar.get(), 'nope')

            for j in range(2):
                fut = self.loop.create_future()
                fut.add_done_callback(fut_on_done)
                cvar.set('yes{}'.format(j))
                self.loop.call_soon(fut.set_result, None)
                await fut
                self.assertEqual(cvar.get(), 'yes{}'.format(j))

                for i in range(3):
                    # Test that task passed its context to add_done_callback:
                    cvar.set('yes{}-{}'.format(i, j))
                    await asyncio.sleep(0.001)
                    self.assertEqual(cvar.get(), 'yes{}-{}'.format(i, j))

        task = self.loop.create_task(main())
        self.loop.run_until_complete(task)

        self.assertEqual(cvar.get(), 'nope')

    def test_task_context_3(self):
        cvar = contextvars.ContextVar('cvar', default=-1)

        # Run 100 Tasks in parallel, each modifying cvar.

        async def sub(num):
            for i in range(10):
                cvar.set(num + i)
                await asyncio.sleep(random.uniform(0.001, 0.05))
                self.assertEqual(cvar.get(), num + i)

        async def main():
            tasks = []
            for i in range(100):
                task = self.loop.create_task(sub(random.randint(0, 10)))
                tasks.append(task)

            await asyncio.gather(*tasks, return_exceptions=True)

        self.loop.run_until_complete(main())

        self.assertEqual(cvar.get(), -1)

    def test_task_context_4(self):
        cvar = contextvars.ContextVar('cvar', default='nope')

        class TrackMe:
            pass
        tracked = TrackMe()
        ref = weakref.ref(tracked)

        async def sub():
            cvar.set(tracked)  # NoQA
            self.loop.call_soon(lambda: None)

        async def main():
            await self.loop.create_task(sub())
            await asyncio.sleep(0.01)

        task = self.loop.create_task(main())
        self.loop.run_until_complete(task)

        del tracked
        self.assertIsNone(ref())

    def _run_test(self, method, **switches):
        switches.setdefault('use_tcp', 'both')
        use_ssl = switches.setdefault('use_ssl', 'no') in {'yes', 'both'}
        names = ['factory']
        options = [(_Protocol, _BufferedProtocol)]
        for k, v in switches.items():
            if v == 'yes':
                options.append((True,))
            elif v == 'no':
                options.append((False,))
            elif v == 'both':
                options.append((True, False))
            else:
                raise ValueError(f"Illegal {k}={v}, can only be yes/no/both")
            names.append(k)

        for combo in itertools.product(*options):
            values = dict(zip(names, combo))
            with self.subTest(**values):
                cvar = contextvars.ContextVar('cvar', default='outer')
                values['proto'] = values.pop('factory')(cvar, loop=self.loop)

                async def test():
                    self.assertEqual(cvar.get(), 'outer')
                    cvar.set('inner')
                    tmp_dir = tempfile.TemporaryDirectory()
                    if use_ssl:
                        values['sslctx'] = self._create_server_ssl_context(
                            self.ONLYCERT, self.ONLYKEY)
                        values['client_sslctx'] = \
                            self._create_client_ssl_context()
                    else:
                        values['sslctx'] = values['client_sslctx'] = None

                    if values['use_tcp']:
                        values['addr'] = ('127.0.0.1', tb.find_free_port())
                        values['family'] = socket.AF_INET
                    else:
                        values['addr'] = tmp_dir.name + '/test.sock'
                        values['family'] = socket.AF_UNIX

                    try:
                        await method(cvar=cvar, **values)
                    finally:
                        tmp_dir.cleanup()

                self.loop.run_until_complete(test())

    def _run_server_test(self, method, async_sock=False, **switches):
        async def test(sslctx, client_sslctx, addr, family, **values):
            if values['use_tcp']:
                srv = await self.loop.create_server(
                    lambda: values['proto'], *addr, ssl=sslctx)
            else:
                srv = await self.loop.create_unix_server(
                    lambda: values['proto'], addr, ssl=sslctx)
            s = socket.socket(family)

            if async_sock:
                s.setblocking(False)
                await self.loop.sock_connect(s, addr)
            else:
                await self.loop.run_in_executor(
                    None, s.connect, addr)
                if values['use_ssl']:
                    values['ssl_sock'] = await self.loop.run_in_executor(
                        None, client_sslctx.wrap_socket, s)

            try:
                await method(s=s, **values)
            finally:
                if values['use_ssl']:
                    values['ssl_sock'].close()
                s.close()
                srv.close()
                await srv.wait_closed()
        return self._run_test(test, **switches)

    def test_create_server_protocol_factory_context(self):
        async def test(cvar, proto, use_tcp, family, addr, **_):
            factory_called_future = self.loop.create_future()

            def factory():
                try:
                    self.assertEqual(cvar.get(), 'inner')
                except Exception as e:
                    factory_called_future.set_exception(e)
                else:
                    factory_called_future.set_result(None)

                return proto

            if use_tcp:
                srv = await self.loop.create_server(factory, *addr)
            else:
                srv = await self.loop.create_unix_server(factory, addr)
            s = socket.socket(family)
            with s:
                s.setblocking(False)
                await self.loop.sock_connect(s, addr)

            try:
                await factory_called_future
            finally:
                srv.close()
                await proto.done
                await srv.wait_closed()

        self._run_test(test)

    def test_create_server_connection_protocol(self):
        async def test(proto, s, **_):
            inner = await proto.connection_made_fut
            self.assertEqual(inner, "inner")

            await self.loop.sock_sendall(s, b'data')
            inner = await proto.data_received_fut
            self.assertEqual(inner, "inner")

            s.shutdown(socket.SHUT_WR)
            inner = await proto.eof_received_fut
            self.assertEqual(inner, "inner")

            s.close()
            await proto.done
            self.assertEqual(proto.connection_lost_ctx, "inner")

        self._run_server_test(test, async_sock=True)

    def test_create_ssl_server_connection_protocol(self):
        async def test(cvar, proto, ssl_sock, **_):
            def resume_reading(transport):
                cvar.set("resume_reading")
                transport.resume_reading()

            try:
                inner = await proto.connection_made_fut
                self.assertEqual(inner, "inner")

                await self.loop.run_in_executor(None, ssl_sock.send, b'data')
                inner = await proto.data_received_fut
                self.assertEqual(inner, "inner")

                if self.implementation != 'asyncio':
                    # this seems to be a bug in asyncio
                    proto.data_received_fut = self.loop.create_future()
                    proto.transport.pause_reading()
                    await self.loop.run_in_executor(None,
                                                    ssl_sock.send, b'data')
                    self.loop.call_soon(resume_reading, proto.transport)
                    inner = await proto.data_received_fut
                    self.assertEqual(inner, "inner")

                    await self.loop.run_in_executor(None, ssl_sock.unwrap)
                else:
                    ssl_sock.shutdown(socket.SHUT_WR)
                inner = await proto.eof_received_fut
                self.assertEqual(inner, "inner")

                await self.loop.run_in_executor(None, ssl_sock.close)
                await proto.done
                self.assertEqual(proto.connection_lost_ctx, "inner")
            finally:
                if self.implementation == 'asyncio':
                    # mute resource warning in asyncio
                    proto.transport.close()

        self._run_server_test(test, use_ssl='yes')

    def test_create_server_manual_connection_lost(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest('this seems to be a bug in asyncio')

        async def test(proto, cvar, **_):
            def close():
                cvar.set('closing')
                proto.transport.close()

            inner = await proto.connection_made_fut
            self.assertEqual(inner, "inner")

            self.loop.call_soon(close)

            await proto.done
            self.assertEqual(proto.connection_lost_ctx, "inner")

        self._run_server_test(test, async_sock=True)

    def test_create_ssl_server_manual_connection_lost(self):
        async def test(proto, cvar, ssl_sock, **_):
            def close():
                cvar.set('closing')
                proto.transport.close()

            inner = await proto.connection_made_fut
            self.assertEqual(inner, "inner")

            if self.implementation == 'asyncio':
                self.loop.call_soon(close)
            else:
                # asyncio doesn't have the flushing phase

                # put the incoming data on-hold
                proto.transport.pause_reading()
                # send data
                await self.loop.run_in_executor(None,
                                                ssl_sock.send, b'hello')
                # schedule a proactive transport close which will trigger
                # the flushing process to retrieve the remaining data
                self.loop.call_soon(close)
                # turn off the reading lock now (this also schedules a
                # resume operation after transport.close, therefore it
                # won't affect our test)
                proto.transport.resume_reading()

            await asyncio.sleep(0)
            await self.loop.run_in_executor(None, ssl_sock.unwrap)
            await proto.done
            self.assertEqual(proto.connection_lost_ctx, "inner")
            self.assertFalse(proto.data_received_fut.done())

        self._run_server_test(test, use_ssl='yes')

    def test_create_connection_protocol(self):
        async def test(cvar, proto, addr, sslctx, client_sslctx, family,
                       use_sock, use_ssl, use_tcp):
            ss = socket.socket(family)
            ss.bind(addr)
            ss.listen(1)

            def accept():
                sock, _ = ss.accept()
                if use_ssl:
                    sock = sslctx.wrap_socket(sock, server_side=True)
                return sock

            async def write_over():
                cvar.set("write_over")
                count = 0
                if use_ssl:
                    proto.transport.set_write_buffer_limits(high=256, low=128)
                    while not proto.transport.get_write_buffer_size():
                        proto.transport.write(b'q' * 16384)
                        count += 1
                else:
                    proto.transport.write(b'q' * 16384)
                    proto.transport.set_write_buffer_limits(high=256, low=128)
                    count += 1
                return count

            s = self.loop.run_in_executor(None, accept)

            try:
                method = ('create_connection' if use_tcp
                          else 'create_unix_connection')
                params = {}
                if use_sock:
                    cs = socket.socket(family)
                    cs.connect(addr)
                    params['sock'] = cs
                    if use_ssl:
                        params['server_hostname'] = '127.0.0.1'
                elif use_tcp:
                    params['host'] = addr[0]
                    params['port'] = addr[1]
                else:
                    params['path'] = addr
                    if use_ssl:
                        params['server_hostname'] = '127.0.0.1'
                if use_ssl:
                    params['ssl'] = client_sslctx
                await getattr(self.loop, method)(lambda: proto, **params)
                s = await s

                inner = await proto.connection_made_fut
                self.assertEqual(inner, "inner")

                await self.loop.run_in_executor(None, s.send, b'data')
                inner = await proto.data_received_fut
                self.assertEqual(inner, "inner")

                if self.implementation != 'asyncio':
                    # asyncio bug
                    count = await self.loop.create_task(write_over())
                    inner = await proto.pause_writing_fut
                    self.assertEqual(inner, "inner")

                    for i in range(count):
                        await self.loop.run_in_executor(None, s.recv, 16384)
                    inner = await proto.resume_writing_fut
                    self.assertEqual(inner, "inner")

                if use_ssl and self.implementation != 'asyncio':
                    await self.loop.run_in_executor(None, s.unwrap)
                else:
                    s.shutdown(socket.SHUT_WR)
                inner = await proto.eof_received_fut
                self.assertEqual(inner, "inner")

                s.close()
                await proto.done
                self.assertEqual(proto.connection_lost_ctx, "inner")
            finally:
                ss.close()
                proto.transport.close()

        self._run_test(test, use_sock='both', use_ssl='both')

    def test_start_tls(self):
        if self.implementation == 'asyncio':
            raise unittest.SkipTest('this seems to be a bug in asyncio')

        async def test(cvar, proto, addr, sslctx, client_sslctx, family,
                       ssl_over_ssl, use_tcp, **_):
            ss = socket.socket(family)
            ss.bind(addr)
            ss.listen(1)

            def accept():
                sock, _ = ss.accept()
                sock = sslctx.wrap_socket(sock, server_side=True)
                if ssl_over_ssl:
                    sock = _SSLSocketOverSSL(sock, sslctx, server_side=True)
                return sock

            s = self.loop.run_in_executor(None, accept)
            transport = None

            try:
                if use_tcp:
                    await self.loop.create_connection(lambda: proto, *addr)
                else:
                    await self.loop.create_unix_connection(lambda: proto, addr)
                inner = await proto.connection_made_fut
                self.assertEqual(inner, "inner")

                cvar.set('start_tls')
                transport = await self.loop.start_tls(
                    proto.transport, proto, client_sslctx,
                    server_hostname='127.0.0.1',
                )

                if ssl_over_ssl:
                    cvar.set('start_tls_over_tls')
                    transport = await self.loop.start_tls(
                        transport, proto, client_sslctx,
                        server_hostname='127.0.0.1',
                    )

                s = await s

                await self.loop.run_in_executor(None, s.send, b'data')
                inner = await proto.data_received_fut
                self.assertEqual(inner, "inner")

                await self.loop.run_in_executor(None, s.unwrap)
                inner = await proto.eof_received_fut
                self.assertEqual(inner, "inner")

                s.close()
                await proto.done
                self.assertEqual(proto.connection_lost_ctx, "inner")
            finally:
                ss.close()
                if transport:
                    transport.close()

        self._run_test(test, use_ssl='yes', ssl_over_ssl='both')

    def test_connect_accepted_socket(self):
        async def test(proto, addr, family, sslctx, client_sslctx,
                       use_ssl, **_):
            ss = socket.socket(family)
            ss.bind(addr)
            ss.listen(1)
            s = self.loop.run_in_executor(None, ss.accept)
            cs = socket.socket(family)
            cs.connect(addr)
            s, _ = await s

            try:
                if use_ssl:
                    cs = self.loop.run_in_executor(
                        None, client_sslctx.wrap_socket, cs)
                    await self.loop.connect_accepted_socket(lambda: proto, s,
                                                            ssl=sslctx)
                    cs = await cs
                else:
                    await self.loop.connect_accepted_socket(lambda: proto, s)

                inner = await proto.connection_made_fut
                self.assertEqual(inner, "inner")

                await self.loop.run_in_executor(None, cs.send, b'data')
                inner = await proto.data_received_fut
                self.assertEqual(inner, "inner")

                if use_ssl and self.implementation != 'asyncio':
                    await self.loop.run_in_executor(None, cs.unwrap)
                else:
                    cs.shutdown(socket.SHUT_WR)
                inner = await proto.eof_received_fut
                self.assertEqual(inner, "inner")

                cs.close()
                await proto.done
                self.assertEqual(proto.connection_lost_ctx, "inner")
            finally:
                proto.transport.close()
                ss.close()

        self._run_test(test, use_ssl='both')

    def test_subprocess_protocol(self):
        cvar = contextvars.ContextVar('cvar', default='outer')
        proto = _SubprocessProtocol(cvar, loop=self.loop)

        async def test():
            self.assertEqual(cvar.get(), 'outer')
            cvar.set('inner')
            await self.loop.subprocess_exec(
                lambda: proto, sys.executable, b'-c',
                b';'.join((b'import sys',
                           b'data = sys.stdin.buffer.read()',
                           b'sys.stdout.buffer.write(data)')))

            try:
                inner = await proto.connection_made_fut
                self.assertEqual(inner, "inner")

                proto.transport.get_pipe_transport(0).write(b'data')
                proto.transport.get_pipe_transport(0).write_eof()
                inner = await proto.data_received_fut
                self.assertEqual(inner, "inner")

                inner = await proto.pipe_connection_lost_fut
                self.assertEqual(inner, "inner")

                inner = await proto.process_exited_fut
                if self.implementation != 'asyncio':
                    # bug in asyncio
                    self.assertEqual(inner, "inner")

                await proto.done
                if self.implementation != 'asyncio':
                    # bug in asyncio
                    self.assertEqual(proto.connection_lost_ctx, "inner")
            finally:
                proto.transport.close()

        self.loop.run_until_complete(test())

    def test_datagram_protocol(self):
        cvar = contextvars.ContextVar('cvar', default='outer')
        proto = _DatagramProtocol(cvar, loop=self.loop)
        server_addr = ('127.0.0.1', 8888)
        client_addr = ('127.0.0.1', 0)

        async def run():
            self.assertEqual(cvar.get(), 'outer')
            cvar.set('inner')

            def close():
                cvar.set('closing')
                proto.transport.close()

            try:
                await self.loop.create_datagram_endpoint(
                    lambda: proto, local_addr=server_addr)
                inner = await proto.connection_made_fut
                self.assertEqual(inner, "inner")

                s = socket.socket(socket.AF_INET, type=socket.SOCK_DGRAM)
                s.bind(client_addr)
                s.sendto(b'data', server_addr)
                inner = await proto.data_received_fut
                self.assertEqual(inner, "inner")

                self.loop.call_soon(close)
                await proto.done
                if self.implementation != 'asyncio':
                    # bug in asyncio
                    self.assertEqual(proto.connection_lost_ctx, "inner")
            finally:
                proto.transport.close()
                s.close()
                # let transports close
                await asyncio.sleep(0.1)

        self.loop.run_until_complete(run())


class Test_UV_Context(_ContextBaseTests, tb.UVTestCase):
    pass


class Test_AIO_Context(_ContextBaseTests, tb.AIOTestCase):
    pass
