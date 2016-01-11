import asyncio

from . import includes as __includes
from .loop import Loop as __BaseLoop


__all__ = ('Loop',)


class Loop(__BaseLoop, asyncio.AbstractEventLoop):
    pass
