import asyncio
import os.path
import tempfile

from uvloop import _testbase as tb
from uvloop.loop import FileSystemEvent


class Test_UV_FS_EVENT_CHANGE(tb.UVTestCase):
    async def _file_writer(self):
        f = await self.q.get()
        while True:
            f.write('hello uvloop\n')
            f.flush()
            x = await self.q.get()
            if x is None:
                return

    def fs_event_setup(self):
        self.change_event_count = 0
        self.fname = ''
        self.q = asyncio.Queue()

    def event_cb(self, ev_fname: bytes, evt: FileSystemEvent):
        _d, fn = os.path.split(self.fname)
        self.assertEqual(ev_fname, fn)
        self.assertEqual(evt, FileSystemEvent.CHANGE)
        self.change_event_count += 1
        if self.change_event_count < 4:
            self.q.put_nowait(0)
        else:
            self.q.put_nowait(None)

    def test_fs_event_change(self):
        self.fs_event_setup()

        async def run(write_task):
            self.q.put_nowait(tf)
            try:
                await asyncio.wait_for(write_task, 4)
            except asyncio.TimeoutError:
                write_task.cancel()

        with tempfile.NamedTemporaryFile('wt') as tf:
            self.fname = tf.name.encode()
            h = self.loop._monitor_fs(tf.name, self.event_cb)
            self.assertFalse(h.cancelled())

            self.loop.run_until_complete(run(
                self.loop.create_task(self._file_writer())))
            h.cancel()
            self.assertTrue(h.cancelled())

        self.assertEqual(self.change_event_count, 4)


class Test_UV_FS_EVENT_RENAME(tb.UVTestCase):
    async def _file_renamer(self):
        await self.q.get()
        os.rename(os.path.join(self.dname, self.changed_name),
                  os.path.join(self.dname, self.changed_name + "-new"))
        await self.q.get()

    def fs_event_setup(self):
        self.dname = ''
        self.changed_name = "hello_fs_event.txt"
        self.changed_set = {self.changed_name, self.changed_name + '-new'}
        self.q = asyncio.Queue()

    def event_cb(self, ev_fname: bytes, evt: FileSystemEvent):
        ev_fname = ev_fname.decode()
        self.assertEqual(evt, FileSystemEvent.RENAME)
        self.changed_set.remove(ev_fname)
        if len(self.changed_set) == 0:
            self.q.put_nowait(None)

    def test_fs_event_rename(self):
        self.fs_event_setup()

        async def run(write_task):
            self.q.put_nowait(0)
            try:
                await asyncio.wait_for(write_task, 4)
            except asyncio.TimeoutError:
                write_task.cancel()

        with tempfile.TemporaryDirectory() as td_name:
            self.dname = td_name
            f = open(os.path.join(td_name, self.changed_name), 'wt')
            f.write('hello!')
            f.close()
            h = self.loop._monitor_fs(td_name, self.event_cb)
            self.assertFalse(h.cancelled())

            self.loop.run_until_complete(run(
                self.loop.create_task(self._file_renamer())))
            h.cancel()
            self.assertTrue(h.cancelled())

        self.assertEqual(len(self.changed_set), 0)
