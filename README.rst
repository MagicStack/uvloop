.. image:: https://img.shields.io/github/workflow/status/MagicStack/uvloop/Tests
    :target: https://github.com/MagicStack/uvloop/actions?query=workflow%3ATests+branch%3Amaster

.. image:: https://img.shields.io/pypi/v/uvloop.svg
    :target: https://pypi.python.org/pypi/uvloop

.. image:: https://pepy.tech/badge/uvloop
    :target: https://pepy.tech/project/uvloop
    :alt: PyPI - Downloads


uvloop is a fast, drop-in replacement of the built-in asyncio
event loop.  uvloop is implemented in Cython and uses libuv
under the hood.

The project documentation can be found
`here <http://uvloop.readthedocs.org/>`_.  Please also check out the
`wiki <https://github.com/MagicStack/uvloop/wiki>`_.


Performance
-----------

uvloop makes asyncio 2-4x faster.

.. image:: https://raw.githubusercontent.com/MagicStack/uvloop/master/performance.png
    :target: http://magic.io/blog/uvloop-blazing-fast-python-networking/

The above chart shows the performance of an echo server with different
message sizes.  The *sockets* benchmark uses ``loop.sock_recv()`` and
``loop.sock_sendall()`` methods; the *streams* benchmark uses asyncio
high-level streams, created by the ``asyncio.start_server()`` function;
and the *protocol* benchmark uses ``loop.create_server()`` with a simple
echo protocol.  Read more about uvloop in a
`blog post <http://magic.io/blog/uvloop-blazing-fast-python-networking/>`_
about it.


Installation
------------

uvloop requires Python 3.7 or greater and is available on PyPI.
Use pip to install it::

    $ pip install uvloop

Note that it is highly recommended to **upgrade pip before** installing
uvloop with::

    $ pip install -U pip


Using uvloop
------------

Call ``uvloop.install()`` before calling ``asyncio.run()`` or
manually creating an asyncio event loop:

.. code:: python

    import asyncio
    import uvloop

    async def main():
        # Main entry-point.
        ...

    uvloop.install()
    asyncio.run(main())


Building From Source
--------------------

To build uvloop, you'll need Python 3.7 or greater:

1. Clone the repository:

   .. code::

    $ git clone --recursive git@github.com:MagicStack/uvloop.git
    $ cd uvloop

2. Create a virtual environment and activate it:

   .. code::

    $ python3.7 -m venv uvloop-dev
    $ source uvloop-dev/bin/activate

3. Install development dependencies:

   ..  code::

    $ pip install -e .[dev]

4. Build and run tests:

   .. code::

    $ make
    $ make test


License
-------

uvloop is dual-licensed under MIT and Apache 2.0 licenses.
