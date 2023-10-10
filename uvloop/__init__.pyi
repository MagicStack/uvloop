import sys

from asyncio import AbstractEventLoop
from collections.abc import Callable, Coroutine
from contextvars import Context
from typing import Any, TypeVar


_T = TypeVar('_T')


def run(
    main: Coroutine[Any, Any, _T],
    *,
    debug: bool | None = ...,
    loop_factory: Callable[[], AbstractEventLoop] | None = ...,
) -> _T: ...
