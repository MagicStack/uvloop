import asyncio

from asyncio.events import BaseDefaultEventLoopPolicy as __BasePolicy

from . import includes as __includes  # NOQA
from . import _patch  # NOQA
from .loop import Loop as __BaseLoop, Future  # NOQA


__all__ = ('new_event_loop', 'EventLoopPolicy')


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

    def __init__(self):
        super().__init__()
        self.__watcher = None

    def _loop_factory(self):
        return new_event_loop()

    def get_child_watcher(self):
        return self.__watcher

    def set_child_watcher(self, watcher):
        self.__watcher = watcher
