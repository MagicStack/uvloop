An implementation of asyncio-compatible event loop on top of libuv.
This is a research prototype, do not use it in production.


# Build Instructions

You'll need `Cython` and Python 3.5.  The best way is to create
a virtual env, so that you'll have `cython` and `python` commands
pointing to the correct tools.

1. `git clone --recursive https://github.com/1st1/uvloop.git`

2. `cd uvloop; make`

3. `make test`
