import asyncio

from asyncio import coroutines


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


_old_format_coroutine = coroutines._format_coroutine
coroutines._format_coroutine = _format_coroutine
