import sys


def _format_coroutine(coro):
    if asyncio.iscoroutine(coro) \
            and not hasattr(coro, 'cr_code') \
            and not hasattr(coro, 'gi_code'):

        # Most likely a Cython coroutine
        coro_name = '{}()'.format(coro.__qualname__ or coro.__name__)

        running = False
        try:
            running = coro.cr_running
        except AttributeError:
            try:
                running = coro.gi_running
            except AttributeError:
                pass

        if running:
            return '{} running'.format(coro_name)
        else:
            return coro_name

    return _old_format_coroutine(coro)


async def _wait_for_data(self, func_name):
    """Wait until feed_data() or feed_eof() is called.

    If stream was paused, automatically resume it.
    """
    if self._waiter is not None:
        raise RuntimeError('%s() called while another coroutine is '
                           'already waiting for incoming data' % func_name)

    assert not self._eof, '_wait_for_data after EOF'

    # Waiting for data while paused will make deadlock, so prevent it.
    if self._paused:
        self._paused = False
        self._transport.resume_reading()

    try:
        create_future = self._loop.create_future
    except AttributeError:
        self._waiter = asyncio.Future(loop=self._loop)
    else:
        self._waiter = create_future()

    try:
        await self._waiter
    finally:
        self._waiter = None


if sys.version_info < (3, 5, 2):
    # In Python 3.5.2 (see PEP 478 for 3.5 release schedule)
    # we won't need to patch anything.

    import asyncio

    from asyncio import coroutines
    from asyncio import streams

    # This is needed to support Cython 'async def' coroutines.
    _old_format_coroutine = coroutines._format_coroutine
    coroutines._format_coroutine = _format_coroutine

    # Fix a possible deadlock, improve performance.
    _old_wait_for_data = streams.StreamReader._wait_for_data
    _wait_for_data.__module__ = _old_wait_for_data.__module__
    streams.StreamReader._wait_for_data = _wait_for_data
