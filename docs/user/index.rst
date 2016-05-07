User Guide
==========

This section of the documentation provides information about how to install
uvloop as well as how to use uvloop.


Installation
------------

`uvloop` is available from PyPI. It requires Python 3.5 and Cython.

Use pip to install it.

.. code-block:: console

    $ pip install uvloop

.. note::

    Use the latest version of Cython to minimise the potential for build
    issues.


Using uvloop
------------

To make asyncio use the event loop provided by `uvloop`, you install the
`uvloop` event loop policy:

.. code-block:: python

    import asyncio
    import uvloop
    asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())


Alternatively, you can create an instance of the loop manually, using:

.. code-block:: python

    import asyncio
    import uvloop
    loop = uvloop.new_event_loop()
    asyncio.set_event_loop(loop)
