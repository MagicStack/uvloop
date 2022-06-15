from uvloop import _testbase as tb


class Test_UV_FS_EVENT_CHANGE(tb.UVTestCase):
    def test_fs_event_change(self):
        self.assertGreater(self.loop.get_uvloop_ptr(), 0)
