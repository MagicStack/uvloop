import asyncio
import subprocess
import sys

from uvloop import _testbase as tb


class TestDealloc(tb.UVTestCase):

    def test_dealloc_1(self):
        # Somewhere between Cython 0.25.2 and 0.26.0 uvloop programs
        # started to trigger the following output:
        #
        #    $ python prog.py
        #    Error in sys.excepthook:
        #
        #    Original exception was:
        #
        # Upon some debugging, it appeared that Handle.__dealloc__ was
        # called at a time where some CPython objects become non-functional,
        # and any exception in __dealloc__ caused CPython to output the
        # above.
        #
        # This regression test starts an event loop in debug mode,
        # lets it run for a brief period of time, and exits the program.
        # This will trigger Handle.__dealloc__, CallbackHandle.__dealloc__,
        # and Loop.__dealloc__ methods.  The test will fail if they produce
        # any unwanted output.

        async def test():
            prog = '''\
import uvloop
import asyncio

async def foo():
    return 42

def main():
    uvloop.install()
    loop = asyncio.get_event_loop()
    loop.set_debug(True)
    loop.run_until_complete(foo())
    # Do not close the loop on purpose: let __dealloc__ methods run.

if __name__ == '__main__':
    main()
            '''

            cmd = sys.executable
            proc = await asyncio.create_subprocess_exec(
                cmd, b'-W', b'ignore', b'-c', prog,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE)

            await proc.wait()
            out = await proc.stdout.read()
            err = await proc.stderr.read()

            return out, err

        out, err = self.loop.run_until_complete(test())
        self.assertEqual(out, b'', 'stdout is not empty')
        self.assertEqual(err, b'', 'stderr is not empty')
