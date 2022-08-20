from uvloop import _testbase as tb
from uvloop.loop import libuv_get_loop_t_ptr, libuv_get_version


class Test_UV_libuv(tb.UVTestCase):
    def test_libuv_get_loop_t_ptr(self):
        loop = self.new_loop()
        cap1 = libuv_get_loop_t_ptr(loop)
        cap2 = libuv_get_loop_t_ptr(loop)
        cap3 = libuv_get_loop_t_ptr(self.new_loop())

        import pyximport

        pyximport.install()

        import cython_helper

        self.assertTrue(cython_helper.capsule_equals(cap1, cap2))
        self.assertFalse(cython_helper.capsule_equals(cap1, cap3))

    def test_libuv_get_version(self):
        self.assertGreater(libuv_get_version(), 0)
