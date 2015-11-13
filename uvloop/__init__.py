import asyncio

from .loop import Loop as BaseLoop, _CFUTURE


__all__ = ('Loop',)


class Loop(BaseLoop, asyncio.AbstractEventLoop):
    pass


if _CFUTURE:
    # Monkey-patching is EVIL.
    from .futures import Future as _CFuture
    _orig_Future = asyncio.Future

    class FutureMeta(type):
        def __instancecheck__(cls, instance):
            return (instance.__class__ is _CFuture or
                    isinstance(instance, _orig_Future))

    class Future(asyncio.Future, metaclass=FutureMeta):
        pass

    asyncio.Future = Future
    asyncio.futures.Future = Future

