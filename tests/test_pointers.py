from uvloop import _testbase as tb


class Test_UV_Pointers(tb.UVTestCase):
    def test_get_uvloop_ptr(self):
        self.assertGreater(self.new_loop().get_uvloop_ptr(), 0)

    def test_get_uvloop_ptr_capsule(self):
        self.assertIsNotNone(self.new_loop().get_uvloop_ptr_capsule())
