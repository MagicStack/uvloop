import asyncio

from . import includes as __includes
from .loop import Loop as __BaseLoop


class _Loop(__BaseLoop, asyncio.AbstractEventLoop):
    pass


def new_event_loop():
    return _Loop()
