import asyncio
import collections

cdef CancelledError = asyncio.CancelledError
cdef TimeoutError = asyncio.TimeoutError
cdef Future = asyncio.Future
cdef Task = asyncio.Task
cdef ensure_future = asyncio.ensure_future

cdef deque = collections.deque

del asyncio, collections
