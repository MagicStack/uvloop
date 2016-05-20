# LICENSE: PSF.

import asyncio

from asyncio import test_utils
from uvloop import _testbase as tb


class Dummy:

    def __repr__(self):
        return '<Dummy>'

    def __call__(self, *args):
        pass


def format_coroutine(qualname, state, src, source_traceback, generator=False):
    if generator:
        state = '%s' % state
    else:
        state = '%s, defined' % state
    if source_traceback is not None:
        frame = source_traceback[-1]
        return ('coro=<%s() %s at %s> created at %s:%s'
                % (qualname, state, src, frame[0], frame[1]))
    else:
        return 'coro=<%s() %s at %s>' % (qualname, state, src)


class _TestTasks:

    def test_task_repr(self):
        self.loop.set_debug(False)

        @asyncio.coroutine
        def notmuch():
            yield from []
            return 'abc'

        # test coroutine function
        self.assertEqual(notmuch.__name__, 'notmuch')
        self.assertEqual(notmuch.__qualname__,
                         '_TestTasks.test_task_repr.<locals>.notmuch')
        self.assertEqual(notmuch.__module__, __name__)

        filename, lineno = test_utils.get_function_source(notmuch)
        src = "%s:%s" % (filename, lineno)

        # test coroutine object
        gen = notmuch()
        coro_qualname = '_TestTasks.test_task_repr.<locals>.notmuch'
        self.assertEqual(gen.__name__, 'notmuch')
        self.assertEqual(gen.__qualname__, coro_qualname)

        # test pending Task
        t = asyncio.Task(gen, loop=self.loop)
        t.add_done_callback(Dummy())

        coro = format_coroutine(coro_qualname, 'running', src,
                                t._source_traceback, generator=True)
        self.assertEqual(repr(t),
                         '<Task pending %s cb=[<Dummy>()]>' % coro)

        # test canceling Task
        t.cancel()  # Does not take immediate effect!
        self.assertEqual(repr(t),
                         '<Task cancelling %s cb=[<Dummy>()]>' % coro)

        # test canceled Task
        self.assertRaises(asyncio.CancelledError,
                          self.loop.run_until_complete, t)
        coro = format_coroutine(coro_qualname, 'done', src,
                                t._source_traceback)
        self.assertEqual(repr(t),
                         '<Task cancelled %s>' % coro)

        # test finished Task
        t = asyncio.Task(notmuch(), loop=self.loop)
        self.loop.run_until_complete(t)
        coro = format_coroutine(coro_qualname, 'done', src,
                                t._source_traceback)
        self.assertEqual(repr(t),
                         "<Task finished %s result='abc'>" % coro)

    def test_task_basics(self):
        @asyncio.coroutine
        def outer():
            a = yield from inner1()
            b = yield from inner2()
            return a + b

        @asyncio.coroutine
        def inner1():
            return 42

        @asyncio.coroutine
        def inner2():
            return 1000

        t = outer()
        self.assertEqual(self.loop.run_until_complete(t), 1042)

    def test_task_cancel_yield(self):
        @asyncio.coroutine
        def task():
            while True:
                yield
            return 12

        t = self.create_task(task())
        test_utils.run_briefly(self.loop)  # start coro
        t.cancel()
        self.assertRaises(
            asyncio.CancelledError, self.loop.run_until_complete, t)
        self.assertTrue(t.done())
        self.assertTrue(t.cancelled())
        self.assertFalse(t.cancel())

    def test_task_cancel_inner_future(self):
        f = self.create_future()

        @asyncio.coroutine
        def task():
            yield from f
            return 12

        t = self.create_task(task())
        test_utils.run_briefly(self.loop)  # start task
        f.cancel()
        with self.assertRaises(asyncio.CancelledError):
            self.loop.run_until_complete(t)
        self.assertTrue(f.cancelled())
        self.assertTrue(t.cancelled())

    def test_task_cancel_both_task_and_inner_future(self):
        f = self.create_future()

        @asyncio.coroutine
        def task():
            yield from f
            return 12

        t = self.create_task(task())
        self.assertEqual(asyncio.Task.all_tasks(loop=self.loop), {t})
        test_utils.run_briefly(self.loop)

        f.cancel()
        t.cancel()

        with self.assertRaises(asyncio.CancelledError):
            self.loop.run_until_complete(t)

        self.assertTrue(t.done())
        self.assertTrue(f.cancelled())
        self.assertTrue(t.cancelled())

    def test_task_cancel_task_catching(self):
        fut1 = self.create_future()
        fut2 = self.create_future()

        @asyncio.coroutine
        def task():
            yield from fut1
            try:
                yield from fut2
            except asyncio.CancelledError:
                return 42

        t = self.create_task(task())
        test_utils.run_briefly(self.loop)
        self.assertIs(t._fut_waiter, fut1)  # White-box test.
        fut1.set_result(None)
        test_utils.run_briefly(self.loop)
        self.assertIs(t._fut_waiter, fut2)  # White-box test.
        t.cancel()
        self.assertTrue(fut2.cancelled())
        res = self.loop.run_until_complete(t)
        self.assertEqual(res, 42)
        self.assertFalse(t.cancelled())

    def test_task_cancel_task_ignoring(self):
        fut1 = self.create_future()
        fut2 = self.create_future()
        fut3 = self.create_future()

        @asyncio.coroutine
        def task():
            yield from fut1
            try:
                yield from fut2
            except asyncio.CancelledError:
                pass
            res = yield from fut3
            return res

        t = self.create_task(task())
        test_utils.run_briefly(self.loop)
        self.assertIs(t._fut_waiter, fut1)  # White-box test.
        fut1.set_result(None)
        test_utils.run_briefly(self.loop)
        self.assertIs(t._fut_waiter, fut2)  # White-box test.
        t.cancel()
        self.assertTrue(fut2.cancelled())
        test_utils.run_briefly(self.loop)
        self.assertIs(t._fut_waiter, fut3)  # White-box test.
        fut3.set_result(42)
        res = self.loop.run_until_complete(t)
        self.assertEqual(res, 42)
        self.assertFalse(fut3.cancelled())
        self.assertFalse(t.cancelled())

    def test_task_cancel_current_task(self):
        @asyncio.coroutine
        def task():
            t.cancel()
            self.assertTrue(t._must_cancel)  # White-box test.
            # The sleep should be canceled immediately.
            yield from asyncio.sleep(100, loop=self.loop)
            return 12

        t = self.create_task(task())
        self.assertRaises(
            asyncio.CancelledError, self.loop.run_until_complete, t)
        self.assertTrue(t.done())
        self.assertFalse(t._must_cancel)  # White-box test.
        self.assertFalse(t.cancel())

    def test_task_step_with_baseexception(self):
        @asyncio.coroutine
        def notmutch():
            raise BaseException()

        task = self.create_task(notmutch())
        self.assertRaises(BaseException, task._step)

        self.assertTrue(task.done())
        self.assertIsInstance(task.exception(), BaseException)

    def test_task_step_result_future(self):
        # If coroutine returns future, task waits on this future.

        class Fut(asyncio.Future):
            def __init__(self, *args, **kwds):
                self.cb_added = False
                super().__init__(*args, **kwds)

            def add_done_callback(self, fn):
                self.cb_added = True
                super().add_done_callback(fn)

        fut = Fut(loop=self.loop)
        result = None

        @asyncio.coroutine
        def wait_for_future():
            nonlocal result
            result = yield from fut

        t = self.create_task(wait_for_future())
        test_utils.run_briefly(self.loop)
        self.assertTrue(fut.cb_added)

        res = object()
        fut.set_result(res)
        test_utils.run_briefly(self.loop)
        self.assertIs(res, result)
        self.assertTrue(t.done())
        self.assertIsNone(t.result())

    def test_task_step_result(self):
        @asyncio.coroutine
        def notmuch():
            yield None
            yield 1
            return 'ko'

        self.assertRaises(
            RuntimeError, self.loop.run_until_complete, notmuch())

    def test_task_yield_vs_yield_from(self):
        fut = asyncio.Future(loop=self.loop)

        @asyncio.coroutine
        def wait_for_future():
            yield fut

        task = wait_for_future()
        with self.assertRaises(RuntimeError):
            self.loop.run_until_complete(task)

        self.assertFalse(fut.done())

    def test_task_current_task(self):
        self.assertIsNone(asyncio.Task.current_task(loop=self.loop))

        @asyncio.coroutine
        def coro(loop):
            self.assertTrue(asyncio.Task.current_task(loop=loop) is task)

        task = self.create_task(coro(self.loop))
        self.loop.run_until_complete(task)
        self.assertIsNone(asyncio.Task.current_task(loop=self.loop))

    def test_task_current_task_with_interleaving_tasks(self):
        self.assertIsNone(asyncio.Task.current_task(loop=self.loop))

        fut1 = self.create_future()
        fut2 = self.create_future()

        @asyncio.coroutine
        def coro1(loop):
            self.assertTrue(asyncio.Task.current_task(loop=loop) is task1)
            yield from fut1
            self.assertTrue(asyncio.Task.current_task(loop=loop) is task1)
            fut2.set_result(True)

        @asyncio.coroutine
        def coro2(loop):
            self.assertTrue(asyncio.Task.current_task(loop=loop) is task2)
            fut1.set_result(True)
            yield from fut2
            self.assertTrue(asyncio.Task.current_task(loop=loop) is task2)

        task1 = self.create_task(coro1(self.loop))
        task2 = self.create_task(coro2(self.loop))

        self.loop.run_until_complete(asyncio.wait((task1, task2),
                                                  loop=self.loop))
        self.assertIsNone(asyncio.Task.current_task(loop=self.loop))

    def test_task_yield_future_passes_cancel(self):
        # Canceling outer() cancels inner() cancels waiter.
        proof = 0
        waiter = self.create_future()

        @asyncio.coroutine
        def inner():
            nonlocal proof
            try:
                yield from waiter
            except asyncio.CancelledError:
                proof += 1
                raise
            else:
                self.fail('got past sleep() in inner()')

        @asyncio.coroutine
        def outer():
            nonlocal proof
            try:
                yield from inner()
            except asyncio.CancelledError:
                proof += 100  # Expect this path.
            else:
                proof += 10

        f = asyncio.ensure_future(outer(), loop=self.loop)
        test_utils.run_briefly(self.loop)
        f.cancel()
        self.loop.run_until_complete(f)
        self.assertEqual(proof, 101)
        self.assertTrue(waiter.cancelled())

    def test_task_yield_wait_does_not_shield_cancel(self):
        # Canceling outer() makes wait() return early, leaves inner()
        # running.
        proof = 0
        waiter = self.create_future()

        @asyncio.coroutine
        def inner():
            nonlocal proof
            yield from waiter
            proof += 1

        @asyncio.coroutine
        def outer():
            nonlocal proof
            d, p = yield from asyncio.wait([inner()], loop=self.loop)
            proof += 100

        f = asyncio.ensure_future(outer(), loop=self.loop)
        test_utils.run_briefly(self.loop)
        f.cancel()
        self.assertRaises(
            asyncio.CancelledError, self.loop.run_until_complete, f)
        waiter.set_result(None)
        test_utils.run_briefly(self.loop)
        self.assertEqual(proof, 1)


###############################################################################
# Tests Matrix
###############################################################################


class Test_UV_UV_Tasks(_TestTasks, tb.UVTestCase):
    def create_future(self):
        return self.loop.create_future()

    def create_task(self, coro):
        return self.loop.create_task(coro)


class Test_UV_UV_Tasks_AIO_Future(_TestTasks, tb.UVTestCase):
    def create_future(self):
        return asyncio.Future(loop=self.loop)

    def create_task(self, coro):
        return self.loop.create_task(coro)


class Test_UV_AIO_Tasks(_TestTasks, tb.UVTestCase):
    def create_future(self):
        return asyncio.Future(loop=self.loop)

    def create_task(self, coro):
        return asyncio.Task(coro, loop=self.loop)


class Test_AIO_Tasks(_TestTasks, tb.AIOTestCase):
    def create_future(self):
        return asyncio.Future(loop=self.loop)

    def create_task(self, coro):
        return asyncio.Task(coro, loop=self.loop)
