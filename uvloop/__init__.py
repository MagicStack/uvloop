import asyncio as __asyncio

from asyncio.events import BaseDefaultEventLoopPolicy as __BasePolicy

from . import includes as __includes  # NOQA
from . import _patch  # NOQA
from .loop import Loop as __BaseLoop  # NOQA


__version__ = '0.13.0rc1'
__all__ = ('new_event_loop', 'install', 'EventLoopPolicy')


class Loop(__BaseLoop, __asyncio.AbstractEventLoop):
    pass


def new_event_loop():
    """Return a new event loop."""
    return Loop()


def install():
    """A helper function to install uvloop policy."""
    __asyncio.set_event_loop_policy(EventLoopPolicy())


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
