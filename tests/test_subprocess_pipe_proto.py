import unittest

from uvloop.loop import ReadSubprocessPipeProto, WriteSubprocessPipeProto


class TestSubprocessPipeProto(unittest.TestCase):
    def test_rejects_non_process_owner(self):
        with self.assertRaises(TypeError):
            ReadSubprocessPipeProto(1, 7)
        with self.assertRaises(TypeError):
            WriteSubprocessPipeProto(1, 7)

    def test_rejects_non_int_fd(self):
        # Owner is checked first. A non-process still must not segfault.
        with self.assertRaises(TypeError):
            WriteSubprocessPipeProto(object(), 'nope')
