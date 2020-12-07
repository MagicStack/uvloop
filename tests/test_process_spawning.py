import asyncio
import ctypes.util
import logging
from concurrent.futures import ThreadPoolExecutor
from threading import Thread
from unittest import TestCase

import uvloop


class ProcessSpawningTestCollection(TestCase):

    def test_spawning_external_process(self):
        """Test spawning external process (using `popen` system call) that
        cause loop freeze."""

        async def run(loop):
            event = asyncio.Event()

            dummy_workers = [simulate_loop_activity(loop, event)
                             for _ in range(5)]
            spawn_worker = spawn_external_process(loop, event)
            done, pending = await asyncio.wait([
                asyncio.ensure_future(fut)
                for fut in ([spawn_worker] + dummy_workers)
            ])
            exceptions = [result.exception()
                          for result in done if result.exception()]
            if exceptions:
                raise exceptions[0]

            return True

        async def simulate_loop_activity(loop, done_event):
            """Simulate loop activity by busy waiting for event."""
            while True:
                try:
                    await asyncio.wait_for(done_event.wait(), timeout=0.1)
                except asyncio.TimeoutError:
                    pass

                if done_event.is_set():
                    return None

        async def spawn_external_process(loop, event):
            executor = ThreadPoolExecutor()
            try:
                call = loop.run_in_executor(executor, spawn_process)
                await asyncio.wait_for(call, timeout=3600)
            finally:
                event.set()
                executor.shutdown(wait=False)
            return True

        BUFFER_LENGTH = 1025
        BufferType = ctypes.c_char * (BUFFER_LENGTH - 1)

        def run_echo(popen, fread, pclose):
            fd = popen('echo test'.encode('ASCII'), 'r'.encode('ASCII'))
            try:
                while True:
                    buffer = BufferType()
                    data = ctypes.c_void_p(ctypes.addressof(buffer))

                    # -> this call will freeze whole loop in case of bug
                    read = fread(data, 1, BUFFER_LENGTH, fd)
                    if not read:
                        break
            except Exception:
                logging.getLogger().exception('read error')
                raise
            finally:
                pclose(fd)

        def spawn_process():
            """Spawn external process via `popen` system call."""

            stdio = ctypes.CDLL(ctypes.util.find_library('c'))

            # popen system call
            popen = stdio.popen
            popen.argtypes = (ctypes.c_char_p, ctypes.c_char_p)
            popen.restype = ctypes.c_void_p

            # pclose system call
            pclose = stdio.pclose
            pclose.argtypes = (ctypes.c_void_p,)
            pclose.restype = ctypes.c_int

            # fread system call
            fread = stdio.fread
            fread.argtypes = (ctypes.c_void_p, ctypes.c_size_t,
                              ctypes.c_size_t, ctypes.c_void_p)
            fread.restype = ctypes.c_size_t

            for iteration in range(1000):
                t = Thread(target=run_echo,
                           args=(popen, fread, pclose),
                           daemon=True)
                t.start()
                t.join(timeout=10.0)
                if t.is_alive():
                    raise Exception('process freeze detected at {}'
                                    .format(iteration))

            return True

        loop = uvloop.new_event_loop()
        proc = loop.run_until_complete(run(loop))
        self.assertTrue(proc)
