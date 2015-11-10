from uvloop._testbase import UVTestCase


class TestTimers(UVTestCase):
    def test_timers_1(self):
        self.loop.call_soon(lambda: print('aaaaaaaaaaaa') or self.loop.stop())
        self.loop.run_forever()
