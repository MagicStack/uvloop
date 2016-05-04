.. image:: https://travis-ci.org/MagicStack/uvloop.svg?branch=master
    :target: https://travis-ci.org/MagicStack/uvloop


uvloop is a fast, drop-in replacement of the built-in asyncio
event loop.  uvloop is implemented in Cython and uses libuv
under the hood.


Installation
------------

uvloop is available on PyPI, so you can simply use pip::

    $ pip install uvloop


Using uvloop
------------

To make asyncio use uvloop, you can install the uvloop event
loop policy::

    import asyncio
    import uvloop
    asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())

Or, alternatively, you can create an instance of the loop
manually, using::

    loop = uvloop.new_event_loop()
    asyncio.set_event_loop(loop)


Development of uvloop
---------------------

To build uvloop, you'll need `Cython` and Python 3.5.  The best way
is to create a virtual env, so that you'll have `cython` and `python`
commands pointing to the correct tools.

1. `git clone --recursive git@github.com:MagicStack/uvloop.git`

2. `cd uvloop`

3. `make`

4. `make test`
