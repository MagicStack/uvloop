"""Utilities shared by tests."""
import sys
import contextlib
import logging
import socket
import time
import inspect
import functools

from asyncio.log import logger
from asyncio import futures
from asyncio import tasks
from socket import socketpair


def run_briefly(loop):
    async def once():
        pass
    gen = once()
    t = loop.create_task(gen)
    # Don't log a warning if the task is not done after run_until_complete().
    # It occurs if the loop is stopped or if a task raises a BaseException.
    t._log_destroy_pending = False
    try:
        loop.run_until_complete(t)
    finally:
        gen.close()


def run_until(loop, pred, timeout=30):
    deadline = time.time() + timeout
    while not pred():
        if timeout is not None:
            timeout = deadline - time.time()
            if timeout <= 0:
                raise futures.TimeoutError()
        loop.run_until_complete(tasks.sleep(0.001, loop=loop))


def run_once(loop):
    """Legacy API to run once through the event loop.

    This is the recommended pattern for test code.  It will poll the
    selector once and run all callbacks scheduled in response to I/O
    events.
    """
    loop.call_soon(loop.stop)
    loop.run_forever()


@contextlib.contextmanager
def disable_logger():
    """Context manager to disable asyncio logger.

    For example, it can be used to ignore warnings in debug mode.
    """
    old_level = logger.level
    try:
        logger.setLevel(logging.CRITICAL+1)
        yield
    finally:
        logger.setLevel(old_level)


def mock_nonblocking_socket(proto=socket.IPPROTO_TCP, type=socket.SOCK_STREAM,
                            family=socket.AF_INET):
    """Create a mock of a non-blocking socket."""
    sock = mock.MagicMock(socket.socket)
    sock.proto = proto
    sock.type = type
    sock.family = family
    sock.gettimeout.return_value = 0.0
    return sock


def get_function_source(func):
    if sys.version_info >= (3, 4):
        func = inspect.unwrap(func)
    elif hasattr(func, '__wrapped__'):
        func = func.__wrapped__
    if inspect.isfunction(func):
        code = func.__code__
        return (code.co_filename, code.co_firstlineno)
    if isinstance(func, functools.partial):
        return _get_function_source(func.func)
    if compat.PY34 and isinstance(func, functools.partialmethod):
        return _get_function_source(func.func)
    return None
