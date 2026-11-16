import asyncio
import contextlib
import os.path
import tempfile

from uvloop import _testbase as tb
from uvloop.loop import FileSystemEvent


class Test_UV_FS_Event(tb.UVTestCase):
    def setUp(self):
        super().setUp()
        self.exit_stack = contextlib.ExitStack()
        self.tmp_dir = self.exit_stack.enter_context(
            tempfile.TemporaryDirectory()
        )

    def tearDown(self):
        self.exit_stack.close()
        super().tearDown()

    def test_fs_event_change(self):
        change_event_count = 0
        filename = "fs_event_change.txt"
        path = os.path.join(self.tmp_dir, filename)
        q = asyncio.Queue()

        with open(path, 'wt') as f:
            async def file_writer():
                while True:
                    f.write('hello uvloop\n')
                    f.flush()
                    x = await q.get()
                    if x is None:
                        return

            def event_cb(ev_fname: bytes, evt: FileSystemEvent):
                nonlocal change_event_count
                self.assertEqual(ev_fname, filename.encode())
                self.assertEqual(evt, FileSystemEvent.CHANGE)
                change_event_count += 1
                if change_event_count < 4:
                    q.put_nowait(0)
                else:
                    q.put_nowait(None)

            h = self.loop._monitor_fs(path, event_cb)
            self.loop.run_until_complete(
                asyncio.sleep(0.1)  # let monitor start
            )
            self.assertFalse(h.cancelled())

            self.loop.run_until_complete(asyncio.wait_for(file_writer(), 4))
            h.cancel()
            self.assertTrue(h.cancelled())

        self.assertEqual(change_event_count, 4)

    def test_fs_event_rename(self):
        orig_name = "hello_fs_event.txt"
        new_name = "hello_fs_event_rename.txt"
        changed_set = {orig_name, new_name}
        event = asyncio.Event()

        async def file_renamer():
            os.rename(os.path.join(self.tmp_dir, orig_name),
                      os.path.join(self.tmp_dir, new_name))
            await event.wait()

        def event_cb(ev_fname: bytes, evt: FileSystemEvent):
            ev_fname = ev_fname.decode()
            self.assertEqual(evt, FileSystemEvent.RENAME)
            changed_set.discard(ev_fname)
            if len(changed_set) == 0:
                event.set()

        with open(os.path.join(self.tmp_dir, orig_name), 'wt') as f:
            f.write('hello!')
        h = self.loop._monitor_fs(self.tmp_dir, event_cb)
        self.loop.run_until_complete(asyncio.sleep(0.5))  # let monitor start
        self.assertFalse(h.cancelled())

        self.loop.run_until_complete(asyncio.wait_for(file_renamer(), 4))
        h.cancel()
        self.assertTrue(h.cancelled())

        self.assertEqual(len(changed_set), 0)
