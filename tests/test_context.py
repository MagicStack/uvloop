import asyncio
import decimal
import random
import sys
import unittest
import weakref

from uvloop import _testbase as tb


PY37 = sys.version_info >= (3, 7, 0)


class _ContextBaseTests:

    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_task_decimal_context(self):
        async def fractions(t, precision, x, y):
            with decimal.localcontext() as ctx:
                ctx.prec = precision
                a = decimal.Decimal(x) / decimal.Decimal(y)
                await asyncio.sleep(t, loop=self.loop)
                b = decimal.Decimal(x) / decimal.Decimal(y ** 2)
                return a, b

        async def main():
            r1, r2 = await asyncio.gather(
                fractions(0.1, 3, 1, 3), fractions(0.2, 6, 1, 3),
                loop=self.loop)

            return r1, r2

        r1, r2 = self.loop.run_until_complete(main())

        self.assertEqual(str(r1[0]), '0.333')
        self.assertEqual(str(r1[1]), '0.111')

        self.assertEqual(str(r2[0]), '0.333333')
        self.assertEqual(str(r2[1]), '0.111111')

    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_task_context_1(self):
        import contextvars
        cvar = contextvars.ContextVar('cvar', default='nope')

        async def sub():
            await asyncio.sleep(0.01, loop=self.loop)
            self.assertEqual(cvar.get(), 'nope')
            cvar.set('something else')

        async def main():
            self.assertEqual(cvar.get(), 'nope')
            subtask = self.loop.create_task(sub())
            cvar.set('yes')
            self.assertEqual(cvar.get(), 'yes')
            await subtask
            self.assertEqual(cvar.get(), 'yes')

        task = self.loop.create_task(main())
        self.loop.run_until_complete(task)

    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_task_context_2(self):
        import contextvars
        cvar = contextvars.ContextVar('cvar', default='nope')

        async def main():
            def fut_on_done(fut):
                # This change must not pollute the context
                # of the "main()" task.
                cvar.set('something else')

            self.assertEqual(cvar.get(), 'nope')

            for j in range(2):
                fut = self.loop.create_future()
                fut.add_done_callback(fut_on_done)
                cvar.set('yes{}'.format(j))
                self.loop.call_soon(fut.set_result, None)
                await fut
                self.assertEqual(cvar.get(), 'yes{}'.format(j))

                for i in range(3):
                    # Test that task passed its context to add_done_callback:
                    cvar.set('yes{}-{}'.format(i, j))
                    await asyncio.sleep(0.001, loop=self.loop)
                    self.assertEqual(cvar.get(), 'yes{}-{}'.format(i, j))

        task = self.loop.create_task(main())
        self.loop.run_until_complete(task)

        self.assertEqual(cvar.get(), 'nope')

    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_task_context_3(self):
        import contextvars
        cvar = contextvars.ContextVar('cvar', default=-1)

        # Run 100 Tasks in parallel, each modifying cvar.

        async def sub(num):
            for i in range(10):
                cvar.set(num + i)
                await asyncio.sleep(
                    random.uniform(0.001, 0.05), loop=self.loop)
                self.assertEqual(cvar.get(), num + i)

        async def main():
            tasks = []
            for i in range(100):
                task = self.loop.create_task(sub(random.randint(0, 10)))
                tasks.append(task)

            await asyncio.gather(
                *tasks, loop=self.loop, return_exceptions=True)

        self.loop.run_until_complete(main())

        self.assertEqual(cvar.get(), -1)

    @unittest.skipUnless(PY37, 'requires Python 3.7')
    def test_task_context_4(self):
        import contextvars
        cvar = contextvars.ContextVar('cvar', default='nope')

        class TrackMe:
            pass
        tracked = TrackMe()
        ref = weakref.ref(tracked)

        async def sub():
            cvar.set(tracked)  # NoQA
            self.loop.call_soon(lambda: None)

        async def main():
            await self.loop.create_task(sub())
            await asyncio.sleep(0.01, loop=self.loop)

        task = self.loop.create_task(main())
        self.loop.run_until_complete(task)

        del tracked
        self.assertIsNone(ref())


class Test_UV_Context(_ContextBaseTests, tb.UVTestCase):

    @unittest.skipIf(PY37, 'requires Python <3.6')
    def test_context_arg(self):
        def cb():
            pass

        with self.assertRaisesRegex(NotImplementedError,
                                    'requires Python 3.7'):
            self.loop.call_soon(cb, context=1)

        with self.assertRaisesRegex(NotImplementedError,
                                    'requires Python 3.7'):
            self.loop.call_soon_threadsafe(cb, context=1)

        with self.assertRaisesRegex(NotImplementedError,
                                    'requires Python 3.7'):
            self.loop.call_later(0.1, cb, context=1)


class Test_AIO_Context(_ContextBaseTests, tb.AIOTestCase):
    pass
