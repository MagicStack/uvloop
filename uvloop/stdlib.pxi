import asyncio
import collections
import os
import socket
import sys


cdef aio_CancelledError = asyncio.CancelledError
cdef aio_TimeoutError = asyncio.TimeoutError
cdef aio_Future = asyncio.Future
cdef aio_Task = asyncio.Task
cdef aio_ensure_future = asyncio.ensure_future
cdef aio_gather = asyncio.gather

cdef col_deque = collections.deque
cdef col_Iterable = collections.Iterable

cdef int has_AF_INET6 = hasattr(socket, 'AF_INET6')
cdef int has_SO_REUSEPORT = hasattr(socket, 'SO_REUSEPORT')
cdef int has_IPPROTO_IPV6 = hasattr(socket, 'IPPROTO_IPV6')

cdef str os_name = os.name
cdef str sys_platform = sys.platform


# Cython doesn't cliean-up imported objects properly in Py3 mode.
del asyncio, collections, socket, os, sys
