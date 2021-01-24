Developers Guide
================

The project is hosted on `GitHub <https://github.com/MagicStack/uvloop>`_.
and uses `Travis <https://travis-ci.org/MagicStack/uvloop>`_ for
Continuous Integration.

A goal for the `uvloop` project is to provide a drop in replacement for the
`asyncio` event loop. Any deviation from the behavior of the reference
`asyncio` event loop is considered a bug.

If you have found a bug or have an idea for an enhancement that would
improve the library, use the
`bug tracker <https://github.com/MagicStack/uvloop/issues>`_.


Get the source
--------------

.. code-block:: console

    $ git clone --recursive git@github.com:MagicStack/uvloop.git

The ``--recursive`` argument is important. It will fetch the ``libuv`` source
from the `libuv` Github repository.


Build
-----

To build `uvloop`, you'll need ``Cython`` and Python 3.7.

.. note::

    The best way to work on `uvloop` is to create a virtual env, so that
    you'll have Cython and Python commands pointing to the correct
    tools.

    .. code-block:: console

        $ python3 -m venv myvenv
        $ source myvenv/bin/activate

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
rule from the top level directory. This runs the standard library
``unittest`` tool which discovers all the unit tests and runs them.
It actually runs them twice, once with the `PYTHONASYNCIODEBUG` enabled and
once without.

.. code-block:: console

    $ cd uvloop
    $ make test


Individual Tests
++++++++++++++++

Individual unit tests can be run using the standard library ``unittest``
or ``pytest`` package.

The easiest approach to ensure that ``uvloop`` can be found by Python is to
install the package using ``pip``:

.. code-block:: console

    $ cd uvloop
    $ pip install -e .

You can then run the unit tests individually from the tests directory using
``unittest``:

.. code-block:: console

    $ cd uvloop/tests
    $ python -m unittest test_tcp

or using ``pytest``:

.. code-block:: console

    $ cd uvloop/tests
    $ py.test -k test_signals_sigint_uvcode


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
