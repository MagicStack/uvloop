import asyncio
import io
import os
import socket

from uvloop import _testbase as tb


# All tests are copied from asyncio (mostly as-is)


class MyReadPipeProto(asyncio.Protocol):
    done = None

    def __init__(self, loop=None):
        self.state = ['INITIAL']
        self.nbytes = 0
        self.transport = None
        if loop is not None:
            self.done = asyncio.Future(loop=loop)

    def connection_made(self, transport):
        self.transport = transport
        assert self.state == ['INITIAL'], self.state
        self.state.append('CONNECTED')

    def data_received(self, data):
        assert self.state == ['INITIAL', 'CONNECTED'], self.state
        self.nbytes += len(data)

    def eof_received(self):
        assert self.state == ['INITIAL', 'CONNECTED'], self.state
        self.state.append('EOF')

    def connection_lost(self, exc):
        if 'EOF' not in self.state:
            self.state.append('EOF')  # It is okay if EOF is missed.
        assert self.state == ['INITIAL', 'CONNECTED', 'EOF'], self.state
        self.state.append('CLOSED')
        if self.done:
            self.done.set_result(None)


class MyWritePipeProto(asyncio.BaseProtocol):
    done = None
    paused = False

    def __init__(self, loop=None):
        self.state = 'INITIAL'
        self.transport = None
        if loop is not None:
            self.done = asyncio.Future(loop=loop)

    def connection_made(self, transport):
        self.transport = transport
        assert self.state == 'INITIAL', self.state
        self.state = 'CONNECTED'

    def connection_lost(self, exc):
        assert self.state == 'CONNECTED', self.state
        self.state = 'CLOSED'
        if self.done:
            self.done.set_result(None)

    def pause_writing(self):
        self.paused = True

    def resume_writing(self):
        self.paused = False


class _BasePipeTest:
    def test_read_pipe(self):
        proto = MyReadPipeProto(loop=self.loop)

        rpipe, wpipe = os.pipe()
        pipeobj = io.open(rpipe, 'rb', 1024)

        async def connect():
            t, p = await self.loop.connect_read_pipe(
                lambda: proto, pipeobj)
            self.assertIs(p, proto)
            self.assertIs(t, proto.transport)
            self.assertEqual(['INITIAL', 'CONNECTED'], proto.state)
            self.assertEqual(0, proto.nbytes)

        self.loop.run_until_complete(connect())

        os.write(wpipe, b'1')
        tb.run_until(self.loop, lambda: proto.nbytes >= 1)
        self.assertEqual(1, proto.nbytes)

        os.write(wpipe, b'2345')
        tb.run_until(self.loop, lambda: proto.nbytes >= 5)
        self.assertEqual(['INITIAL', 'CONNECTED'], proto.state)
        self.assertEqual(5, proto.nbytes)

        os.close(wpipe)
        self.loop.run_until_complete(proto.done)
        self.assertEqual(
            ['INITIAL', 'CONNECTED', 'EOF', 'CLOSED'], proto.state)
        # extra info is available
        self.assertIsNotNone(proto.transport.get_extra_info('pipe'))

    def test_read_pty_output(self):
        proto = MyReadPipeProto(loop=self.loop)

        master, slave = os.openpty()
        master_read_obj = io.open(master, 'rb', 0)

        async def connect():
            t, p = await self.loop.connect_read_pipe(
                lambda: proto, master_read_obj)
            self.assertIs(p, proto)
            self.assertIs(t, proto.transport)
            self.assertEqual(['INITIAL', 'CONNECTED'], proto.state)
            self.assertEqual(0, proto.nbytes)

        self.loop.run_until_complete(connect())

        os.write(slave, b'1')
        tb.run_until(self.loop, lambda: proto.nbytes)
        self.assertEqual(1, proto.nbytes)

        os.write(slave, b'2345')
        tb.run_until(self.loop, lambda: proto.nbytes >= 5)
        self.assertEqual(['INITIAL', 'CONNECTED'], proto.state)
        self.assertEqual(5, proto.nbytes)

        # On Linux, transport raises EIO when slave is closed --
        # ignore it.
        self.loop.set_exception_handler(lambda loop, ctx: None)
        os.close(slave)
        proto.transport.close()
        self.loop.run_until_complete(proto.done)

        self.assertEqual(
            ['INITIAL', 'CONNECTED', 'EOF', 'CLOSED'], proto.state)
        # extra info is available
        self.assertIsNotNone(proto.transport.get_extra_info('pipe'))

    def test_write_pipe(self):
        rpipe, wpipe = os.pipe()
        os.set_blocking(rpipe, False)
        pipeobj = io.open(wpipe, 'wb', 1024)

        proto = MyWritePipeProto(loop=self.loop)
        connect = self.loop.connect_write_pipe(lambda: proto, pipeobj)
        transport, p = self.loop.run_until_complete(connect)
        self.assertIs(p, proto)
        self.assertIs(transport, proto.transport)
        self.assertEqual('CONNECTED', proto.state)

        transport.write(b'1')

        data = bytearray()

        def reader(data):
            try:
                chunk = os.read(rpipe, 1024)
            except BlockingIOError:
                return len(data)
            data += chunk
            return len(data)

        tb.run_until(self.loop, lambda: reader(data) >= 1)
        self.assertEqual(b'1', data)

        transport.write(b'2345')
        tb.run_until(self.loop, lambda: reader(data) >= 5)
        self.assertEqual(b'12345', data)
        self.assertEqual('CONNECTED', proto.state)

        os.close(rpipe)

        # extra info is available
        self.assertIsNotNone(proto.transport.get_extra_info('pipe'))

        # close connection
        proto.transport.close()
        self.loop.run_until_complete(proto.done)
        self.assertEqual('CLOSED', proto.state)

    def test_write_pipe_disconnect_on_close(self):
        rsock, wsock = socket.socketpair()
        rsock.setblocking(False)

        pipeobj = io.open(wsock.detach(), 'wb', 1024)

        proto = MyWritePipeProto(loop=self.loop)
        connect = self.loop.connect_write_pipe(lambda: proto, pipeobj)
        transport, p = self.loop.run_until_complete(connect)
        self.assertIs(p, proto)
        self.assertIs(transport, proto.transport)
        self.assertEqual('CONNECTED', proto.state)

        transport.write(b'1')
        data = self.loop.run_until_complete(self.loop.sock_recv(rsock, 1024))
        self.assertEqual(b'1', data)

        rsock.close()

        self.loop.run_until_complete(proto.done)
        self.assertEqual('CLOSED', proto.state)

    def test_write_pty(self):
        master, slave = os.openpty()
        os.set_blocking(master, False)

        slave_write_obj = io.open(slave, 'wb', 0)

        proto = MyWritePipeProto(loop=self.loop)
        connect = self.loop.connect_write_pipe(lambda: proto, slave_write_obj)
        transport, p = self.loop.run_until_complete(connect)
        self.assertIs(p, proto)
        self.assertIs(transport, proto.transport)
        self.assertEqual('CONNECTED', proto.state)

        transport.write(b'1')

        data = bytearray()

        def reader(data):
            try:
                chunk = os.read(master, 1024)
            except BlockingIOError:
                return len(data)
            data += chunk
            return len(data)

        tb.run_until(self.loop, lambda: reader(data) >= 1,
                     timeout=10)
        self.assertEqual(b'1', data)

        transport.write(b'2345')
        tb.run_until(self.loop, lambda: reader(data) >= 5,
                     timeout=10)
        self.assertEqual(b'12345', data)
        self.assertEqual('CONNECTED', proto.state)

        os.close(master)

        # extra info is available
        self.assertIsNotNone(proto.transport.get_extra_info('pipe'))

        # close connection
        proto.transport.close()
        self.loop.run_until_complete(proto.done)
        self.assertEqual('CLOSED', proto.state)

    def test_write_buffer_full(self):
        rpipe, wpipe = os.pipe()
        pipeobj = io.open(wpipe, 'wb', 1024)

        proto = MyWritePipeProto(loop=self.loop)
        connect = self.loop.connect_write_pipe(lambda: proto, pipeobj)
        transport, p = self.loop.run_until_complete(connect)
        self.assertIs(p, proto)
        self.assertIs(transport, proto.transport)
        self.assertEqual('CONNECTED', proto.state)

        for i in range(32):
            transport.write(b'x' * 32768)
            if proto.paused:
                transport.write(b'x' * 32768)
                break
        else:
            self.fail("Didn't reach a full buffer")

        os.close(rpipe)
        self.loop.run_until_complete(asyncio.wait_for(proto.done, 1))
        self.assertEqual('CLOSED', proto.state)

    def _assert_pipe_close_does_not_steal_fd(self, connect, make_pipeobj,
                                             close_other_end):
        # Regression test for https://github.com/MagicStack/uvloop/issues/763
        # libuv closes the fd given to it; the Python file object must not
        # close that same fd again (it may have been reused).
        stolen = []
        probed = []

        class FileIOWithProbe(io.FileIO):
            def close(self):
                try:
                    fd = super().fileno()
                except (ValueError, OSError):
                    super().close()
                    return
                try:
                    os.fstat(fd)
                    already_closed = False
                except OSError:
                    already_closed = True
                probed.append('closed' if already_closed else 'open')
                new_r, new_w = os.pipe()
                try:
                    super().close()
                finally:
                    for nfd in (new_r, new_w):
                        try:
                            os.fstat(nfd)
                        except OSError:
                            stolen.append(nfd)
                        else:
                            os.close(nfd)
                    if already_closed:
                        stolen.append(fd)

        async def main():
            pipe_read_fd, pipe_write_fd = os.pipe()
            lost = self.loop.create_future()

            class Proto(asyncio.Protocol):
                def connection_lost(self, exc):
                    if not lost.done():
                        lost.set_result(None)

            pipeobj = make_pipeobj(FileIOWithProbe, pipe_read_fd,
                                   pipe_write_fd)
            transport, _ = await connect(Proto, pipeobj)
            transport.close()
            await lost
            close_other_end(pipe_read_fd, pipe_write_fd)

        self.loop.run_until_complete(main())
        self.assertIn('open', probed)
        self.assertEqual(stolen, [])

    def test_read_pipe_close_does_not_steal_fd(self):
        def make_pipeobj(fileio_cls, read_fd, write_fd):
            return io.BufferedReader(fileio_cls(read_fd, 'rb'))

        async def connect(proto_factory, pipeobj):
            return await self.loop.connect_read_pipe(proto_factory, pipeobj)

        def close_other_end(read_fd, write_fd):
            os.close(write_fd)

        self._assert_pipe_close_does_not_steal_fd(
            connect, make_pipeobj, close_other_end)

    def test_write_pipe_close_does_not_steal_fd(self):
        def make_pipeobj(fileio_cls, read_fd, write_fd):
            return io.BufferedWriter(fileio_cls(write_fd, 'wb'))

        async def connect(proto_factory, pipeobj):
            return await self.loop.connect_write_pipe(proto_factory, pipeobj)

        def close_other_end(read_fd, write_fd):
            os.close(read_fd)

        self._assert_pipe_close_does_not_steal_fd(
            connect, make_pipeobj, close_other_end)


class Test_UV_Pipes(_BasePipeTest, tb.UVTestCase):
    pass


class Test_AIO_Pipes(_BasePipeTest, tb.AIOTestCase):
    pass
