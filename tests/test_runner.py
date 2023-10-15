import asyncio
import unittest
import uvloop


class TestSourceCode(unittest.TestCase):

    def test_uvloop_run_1(self):
        CNT = 0

        async def main():
            nonlocal CNT
            CNT += 1

            loop = asyncio.get_running_loop()

            self.assertTrue(isinstance(loop, uvloop.Loop))
            self.assertTrue(loop.get_debug())

            return 'done'

        result = uvloop.run(main(), debug=True)

        self.assertEqual(result, 'done')
        self.assertEqual(CNT, 1)

    def test_uvloop_run_2(self):

        async def main():
            pass

        coro = main()
        with self.assertRaisesRegex(TypeError, ' a non-uvloop event loop'):
            uvloop.run(
                coro,
                loop_factory=asyncio.DefaultEventLoopPolicy().new_event_loop,
            )

        coro.close()
