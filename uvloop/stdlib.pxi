import asyncio, asyncio.log, asyncio.base_events
import collections
import concurrent.futures
import functools
import os
import socket
import sys

from . import futures
cdef c_Future = futures.Future

cdef aio_CancelledError = asyncio.CancelledError
cdef aio_TimeoutError = asyncio.TimeoutError
cdef aio_Future = asyncio.Future
cdef aio_Task = asyncio.Task
cdef aio_ensure_future = asyncio.ensure_future
cdef aio_gather = asyncio.gather
cdef aio_logger = asyncio.log.logger
cdef aio_coroutine = asyncio.coroutine
cdef aio__check_resolved_address = asyncio.base_events._check_resolved_address
cdef aio_iscoroutine = asyncio.iscoroutine
cdef aio_iscoroutinefunction = asyncio.iscoroutinefunction
cdef aio_wrap_future = asyncio.wrap_future

cdef col_deque = collections.deque
cdef col_Iterable = collections.Iterable

cdef cc_ThreadPoolExecutor = concurrent.futures.ThreadPoolExecutor

cdef ft_partial = functools.partial

cdef int has_AF_INET6 = hasattr(socket, 'AF_INET6')
cdef int has_SO_REUSEPORT = hasattr(socket, 'SO_REUSEPORT')
cdef int has_IPPROTO_IPV6 = hasattr(socket, 'IPPROTO_IPV6')

cdef str os_name = os.name
cdef os_environ = os.environ

cdef str sys_platform = sys.platform
cdef sys_ignore_environment = sys.flags.ignore_environment


# Cython doesn't clean-up imported objects properly in Py3 mode.
del asyncio, concurrent, collections, futures, functools, socket, os, sys
