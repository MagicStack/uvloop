Developers Guide
================

The project is hosted on `GitHub <https://github.com/MagicStack/uvloop>`_.
and uses `Travis <https://travis-ci.org/MagicStack/uvloop>`_ for
Continuous Integration.

A goal for the `uvloop` project is to provide a drop in replacement for the
`asyncio` event loop. Any deviation from the behavior of the reference
`asyncio` event loop is considered a bug.

If you have found a bug or have an idea for an enhancement that would
improve the library, use the `bug tracker <https://github.com/MagicStack/uvloop/issues>`_.


Get the source
--------------

.. code-block:: console

    $ git clone --recursive git@github.com:MagicStack/uvloop.git

The ``--recursive`` argument is important. It will fetch the ``libuv`` source
from the `libuv` Github repository.


Build
-----

To build `uvloop`, you'll need `Cython` and Python 3.5.

.. note::

    The best way to work on `uvloop` is to create a virtual env, so that
    you'll have Cython and Python commands pointing to the correct
    tools.

    .. code-block:: console

        $ python3 -m venv myvenv
        $ cd myvenv
        $ source bin/activate
        $ cd ..

Install Cython if not already present.

.. code-block:: console

    $ pip install Cython


Build `uvloop` by running the ``make`` rule from the top level directory.

.. code-block:: console

    $ cd uvloop
    $ make


Test
----

The easiest method to run all of the unit tests is to run the ``make test``
rule from the top level directory. This runs the standard
library ``unittest`` tool which discovers all the unit tests and runs them.
It actually runs them twice, once with the `PYTHONASYNCIODEBUG` enabled and
once without.

.. code-block:: console

    $ cd uvloop
    $ make test

Alternatively, you can run the tests from the ``tests`` directory using the
standard library `unittest` approach. When using this approach you must
specify the ``PYTHONPATH`` so that the `uvloop` package can be resolved from
down in the ``tests`` directory.

.. code-block:: console

    $ cd uvloop/tests
    $ PYTHONPATH=$PWD/.. python -m unittest


Individual Tests
++++++++++++++++

Running a specific unittest or even a specific test method is useful for
developer productivity by facilitating faster development iteration.

Individual unit tests can be run using the standard library ``unittest``
or ``pytest``.

During development you are not working with an installed package. With either
approach you need to ensure that the `uvloop` package can be resolved. To do
this you must specify the ``PYTHONPATH`` before launching Python.


unittest
^^^^^^^^

The following example shows how to use ``unittest`` to run all the tests
within a specific test file.

.. code-block:: console

    $ cd uvloop/tests
    $ PYTHONPATH=$PWD/.. python -m unittest test_tcp

You can also run a specific test method too:

.. code-block:: console

    $ cd uvloop/tests
    PYTHONPATH=$PWD/.. python -m unittest test_tcp.Test_UV_TCP.test_create_server_1


pytest
^^^^^^

The same can be achived with ``pytest`` if you prefer to use that.

Individual tests can be run from the top level directory:

.. code-block:: console

    $ cd uvloop
    $ PYTHONPATH=. py.test -k test_signals_sigint_uvcode

Or from within the tests directory:

.. code-block:: console

    $ cd uvloop/tests
    $ PYTHONPATH=$PWD/.. py.test -k test_signals_sigint_uvcode


Documentation
-------------

To rebuild the project documentation, developers should run the ``make docs``
rule from the top level directory. It performs a number of steps to create
a new set of `sphinx <http://sphinx-doc.org/>`_ html content.

This step requires Sphinx to be installed. Sphinx can be installed using
pip:

.. code-block:: console

    $ pip install sphinx

Once Sphinx is available you can make the documentation using:

.. code-block:: console

    $ make docs

To quickly view the docs as you are working on them you can open the
generated ``index.thml`` file or use the simple Python web server.

.. code-block:: console

    $ cd docs/
    $ python3 -m http.server

Then open http://localhost:8000 in a browser and navigate to
``_build/html/index.html``.

.. note::

    Don't start the web server within the ``_build`` directory. Each time
    the docs are rebuilt the `_build` directory is re-created. This avoids
    needing to restart it after each docs rebuild. You can simply hit ``F5``
    to refresh the page to see your doc updates.

