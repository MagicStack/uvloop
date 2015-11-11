import asyncio

from .loop import Loop as BaseLoop


__all__ = ('Loop',)


class Loop(BaseLoop, asyncio.AbstractEventLoop):
    pass


del BaseLoop, asyncio
