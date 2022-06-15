import asyncio
import socket
import tempfile
import unittest

from uvloop import _testbase as tb
from uvloop.const import FS_EVENT_CHANGE, FS_EVENT_RENAME

class Test_UV_FS_EVENT(tb.UVTestCase):
    async def _file_writer(self):
        f = await self.q.get()
        while True:
            f.write('hello uvloop\n')
            x = await self.q.get()
            if x is None:
                return

    def fs_event_setup(self):
        self.change_event_count = 0
        self.fname = ''
        self.q = asyncio.Queue()

    def event_cb(self, ev_fname: bytes, evt: int) :
        self.assertEqual(ev_fname, self.fname)
        self.assertEqual(evt, FS_EVENT_CHANGE)
        self.change_event_count += 1
        if self.change_event_count < 4:
            self.q.put_nowait(0)
        else:
            self.q.put_nowait(None)

    def test_fs_event_change(self):
        self.fs_event_setup()

        async def run(write_task):
            self.q.put_nowait(tf)
            self.q.put_nowait(0)
            try:
                await asyncio.wait_for(write_task, 4)
            except asyncio.TimeoutError:
                write_task.cancel()
            self.loop.stop()

        with tempfile.NamedTemporaryFile('wt') as tf:
            self.fname = tf.name.encode()
            h = self.loop.monitor_fs(tf.name, self.event_cb, 0)
            try :
                self.loop.run_until_complete(run(self.loop.create_task(self._file_writer())))
                h.stop()
            finally :
                self.loop.close()

        self.assertEqual(self.change_event_count, 4)
