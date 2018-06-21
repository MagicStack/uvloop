import asyncio

from asyncio.events import BaseDefaultEventLoopPolicy as __BasePolicy
from sys import version_info

from . import includes as __includes  # NOQA
from . import _patch  # NOQA
from .loop import Loop as __BaseLoop  # NOQA

PY37 = version_info >= (3, 7, 0)

if PY37:
    from .loop import start_tracing, stop_tracing
    __all__ = ('new_event_loop', 'EventLoopPolicy', 'start_tracing', 'stop_tracing')
else:
    __all__ = ('new_event_loop', 'EventLoopPolicy')

__version__ = '0.11.0.dev0'

class Loop(__BaseLoop, asyncio.AbstractEventLoop):
    pass


def new_event_loop():
    """Return a new event loop."""
    return Loop()


class EventLoopPolicy(__BasePolicy):
    """Event loop policy.

    The preferred way to make your application use uvloop:

    >>> import asyncio
    >>> import uvloop
    >>> asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
    >>> asyncio.get_event_loop()
    <uvloop.Loop running=False closed=False debug=False>
    """

    def _loop_factory(self):
        return new_event_loop()
