.. image:: https://travis-ci.org/MagicStack/uvloop.svg?branch=master
    :target: https://travis-ci.org/MagicStack/uvloop

.. image:: https://img.shields.io/pypi/status/uvloop.svg?maxAge=2592000?style=plastic
    :target: https://pypi.python.org/pypi/uvloop


uvloop is a fast, drop-in replacement of the built-in asyncio
event loop.  uvloop is implemented in Cython and uses libuv
under the hood.

Read more about uvloop here:
http://magic.io/blog/uvloop-blazing-fast-python-networking/

The project documentation can be found
`here <http://uvloop.readthedocs.org/>`_.


Installation
------------

uvloop requires Python 3.5 and is available on PyPI.
Use pip to install it::

    $ pip install uvloop


Using uvloop
------------

To make asyncio use uvloop, you can install the uvloop event
loop policy:

.. code:: python

    import asyncio
    import uvloop
    asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())

Or, alternatively, you can create an instance of the loop
manually, using:

.. code:: python

    loop = uvloop.new_event_loop()
    asyncio.set_event_loop(loop)


Development of uvloop
---------------------

To build uvloop, you'll need ``Cython`` and Python 3.5.  The best way
is to create a virtual env, so that you'll have ``cython`` and
``python`` commands pointing to the correct tools.

1. ``git clone --recursive git@github.com:MagicStack/uvloop.git``

2. ``cd uvloop``

3. ``make``

4. ``make test``
