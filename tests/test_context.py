import asyncio
import contextvars
import decimal
import random
import weakref

from uvloop import _testbase as tb


class _ContextBaseTests:

    def test_task_decimal_context(self):
        async def fractions(t, precision, x, y):
            with decimal.localcontext() as ctx:
                ctx.prec = precision
                a = decimal.Decimal(x) / decimal.Decimal(y)
                await asyncio.sleep(t)
                b = decimal.Decimal(x) / decimal.Decimal(y ** 2)
                return a, b

        async def main():
            r1, r2 = await asyncio.gather(
                fractions(0.1, 3, 1, 3), fractions(0.2, 6, 1, 3))

            return r1, r2

        r1, r2 = self.loop.run_until_complete(main())

        self.assertEqual(str(r1[0]), '0.333')
        self.assertEqual(str(r1[1]), '0.111')

        self.assertEqual(str(r2[0]), '0.333333')
        self.assertEqual(str(r2[1]), '0.111111')

    def test_task_context_1(self):
        cvar = contextvars.ContextVar('cvar', default='nope')

        async def sub():
            await asyncio.sleep(0.01)
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

    def test_task_context_2(self):
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
                    await asyncio.sleep(0.001)
                    self.assertEqual(cvar.get(), 'yes{}-{}'.format(i, j))

        task = self.loop.create_task(main())
        self.loop.run_until_complete(task)

        self.assertEqual(cvar.get(), 'nope')

    def test_task_context_3(self):
        cvar = contextvars.ContextVar('cvar', default=-1)

        # Run 100 Tasks in parallel, each modifying cvar.

        async def sub(num):
            for i in range(10):
                cvar.set(num + i)
                await asyncio.sleep(random.uniform(0.001, 0.05))
                self.assertEqual(cvar.get(), num + i)

        async def main():
            tasks = []
            for i in range(100):
                task = self.loop.create_task(sub(random.randint(0, 10)))
                tasks.append(task)

            await asyncio.gather(*tasks, return_exceptions=True)

        self.loop.run_until_complete(main())

        self.assertEqual(cvar.get(), -1)

    def test_task_context_4(self):
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
            await asyncio.sleep(0.01)

        task = self.loop.create_task(main())
        self.loop.run_until_complete(task)

        del tracked
        self.assertIsNone(ref())


class Test_UV_Context(_ContextBaseTests, tb.UVTestCase):
    pass


class Test_AIO_Context(_ContextBaseTests, tb.AIOTestCase):
    pass
