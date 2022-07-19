import uvloop
from uvloop import _testbase as tb
import ctypes
import os.path


class TestGetUvLoopPtr(tb.UVTestCase):
    def test_get_uv_loop_ptr(self):
        so_lib_path = None
        dir_p = os.path.split(uvloop.__file__)[0]
        for n in os.listdir(dir_p):
            if n.endswith('.so'):
                so_lib_path = os.path.join(dir_p, n)
        if so_lib_path is None:
            raise RuntimeError('could not find uvloop shared lib')
        cdll = ctypes.CDLL(so_lib_path)
        self.assertGreater(cdll.get_uv_loop_ptr(ctypes.py_object(self.loop)),
                           0)
