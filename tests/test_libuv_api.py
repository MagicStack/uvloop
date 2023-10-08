from uvloop import _testbase as tb
from uvloop.loop import libuv_get_loop_t_ptr, libuv_get_version
from uvloop.loop import _testhelper_unwrap_capsuled_pointer as unwrap


class Test_UV_libuv(tb.UVTestCase):
    def test_libuv_get_loop_t_ptr(self):
        loop1 = self.new_loop()
        cap1 = libuv_get_loop_t_ptr(loop1)
        cap2 = libuv_get_loop_t_ptr(loop1)

        loop2 = self.new_loop()
        cap3 = libuv_get_loop_t_ptr(loop2)

        try:
            self.assertEqual(unwrap(cap1), unwrap(cap2))
            self.assertNotEqual(unwrap(cap1), unwrap(cap3))
        finally:
            loop1.close()
            loop2.close()

    def test_libuv_get_version(self):
        self.assertGreater(libuv_get_version(), 0)
