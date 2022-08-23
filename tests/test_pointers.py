from uvloop import _testbase as tb


class Test_UV_Pointers(tb.UVTestCase):
    def test_get_uv_loop_t_ptr(self):
        loop = self.new_loop()
        cap1 = loop.get_uv_loop_t_ptr()
        cap2 = loop.get_uv_loop_t_ptr()
        cap3 = self.new_loop().get_uv_loop_t_ptr()

        import pyximport

        pyximport.install()

        from tests import cython_helper

        self.assertTrue(cython_helper.capsule_equals(cap1, cap2))
        self.assertFalse(cython_helper.capsule_equals(cap1, cap3))
