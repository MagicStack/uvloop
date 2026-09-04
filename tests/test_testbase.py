import unittest

from uvloop import _testbase as tb


class TestBaseTest(unittest.TestCase):

    def test_duplicate_methods(self):
        with self.assertRaisesRegex(RuntimeError, 'duplicate test Foo.test_a'):

            class Foo(tb.BaseTestCase):
                def test_a(self):
                    pass

                def test_b(self):
                    pass

                def test_a(self):  # NOQA
                    pass

    def test_duplicate_methods_parent_1(self):
        class FooBase:
            def test_a(self):
                pass

        with self.assertRaisesRegex(RuntimeError,
                                    'duplicate test Foo.test_a.*'
                                    'defined in FooBase'):

            class Foo(FooBase, tb.BaseTestCase):
                def test_b(self):
                    pass

                def test_a(self):
                    pass

    def test_duplicate_methods_parent_2(self):
        class FooBase(tb.BaseTestCase):
            def test_a(self):
                pass

        with self.assertRaisesRegex(RuntimeError,
                                    'duplicate test Foo.test_a.*'
                                    'defined in FooBase'):

            class Foo(FooBase):
                def test_b(self):
                    pass

                def test_a(self):
                    pass
