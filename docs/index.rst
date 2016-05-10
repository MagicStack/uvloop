.. image:: https://travis-ci.org/MagicStack/uvloop.svg?branch=master
    :target: https://travis-ci.org/MagicStack/uvloop

.. image:: https://img.shields.io/pypi/status/uvloop.svg?maxAge=2592000?style=plastic
    :target: https://pypi.python.org/pypi/uvloop

.. image:: https://img.shields.io/github/stars/magicstack/uvloop.svg?style=social&label=GitHub
    :target: https://github.com/MagicStack/uvloop


uvloop
======

`uvloop` is a fast, drop-in replacement of the built-in asyncio event loop.
`uvloop` is released under the MIT license.

`uvloop` and asyncio, combined with the power of async/await in Python 3.5,
makes it easier than ever to write high-performance networking code in Python.

`uvloop` makes asyncio fast. In fact, it is at least 2x faster than nodejs,
gevent, as well as any other Python asynchronous framework. The performance of
uvloop-based asyncio is close to that of Go programs.

You can read more about uvloop in this
`blog post <http://magic.io/blog/uvloop-blazing-fast-python-networking/>`_.

Architecture
------------

The asyncio module, introduced by PEP 3156, is a collection of network
transports, protocols, and streams abstractions, with a pluggable event loop.
The event loop is the heart of asyncio. It provides APIs for:

- scheduling calls,
- transmitting data over the network,
- performing DNS queries,
- handling OS signals,
- convenient abstractions to create servers and connections,
- working with subprocesses asynchronously.

`uvloop` implements the :class:`asyncio.AbstractEventLoop` interface which
means that it provides a drop-in replacement of the asyncio event loop.

`uvloop` is written in Cython and is built on top of libuv.

libuv is a high performance, multiplatform asynchronous I/O library used by
nodejs. Because of how wide-spread and popular nodejs is, libuv is fast and
stable.

`uvloop` implements all asyncio event loop APIs. High-level Python objects
wrap low-level libuv structs and functions. Inheritance is used to keep the
code DRY and ensure that any manual memory management is in sync with libuv
primitives' lifespans.


Contents
--------

.. toctree::
   :maxdepth: 1

   user/index
   dev/index
   api/index
