from asyncio import AbstractEventLoop
from .loop import Loop as BaseLoop


__all__ = ('Loop',)


class Loop(BaseLoop, AbstractEventLoop):
    pass
