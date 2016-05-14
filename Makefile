.PHONY: compile clean all distclean test debug sdist clean-libuv
.PHONY: release sdist-libuv docs


all: clean compile


clean:
	rm -fr dist/ doc/_build/
	rm -fr uvloop/*.c uvloop/*.html uvloop/*.so build *.egg-info
	rm -fr uvloop/handles/*.html uvloop/includes/*.html
	find . -name '__pycache__' | xargs rm -rf


clean-libuv:
	git -C vendor/libuv clean -dfX


sdist-libuv: clean-libuv
	/bin/sh vendor/libuv/autogen.sh


distclean: clean clean-libuv


compile: clean
	echo "DEF DEBUG = 0" > uvloop/__debug.pxi
	cython -3 uvloop/loop.pyx; rm uvloop/__debug.*
	@echo "$$UVLOOP_BUILD_PATCH_SCRIPT" | python
	python setup.py build_ext --inplace


debug: clean
	echo "DEF DEBUG = 1" > uvloop/__debug.pxi
	cython -3 -a -p uvloop/loop.pyx; rm uvloop/__debug.*
	@echo "$$UVLOOP_BUILD_PATCH_SCRIPT" | python
	python setup.py build_ext --inplace


docs: compile
	cd docs && python -m sphinx -a -b html . _build/html


test:
	PYTHONASYNCIODEBUG=1 python -m unittest discover -s tests
	python -m unittest discover -s tests


sdist: clean compile test sdist-libuv
	python setup.py sdist


release: clean compile test sdist-libuv
	python setup.py sdist upload


# Script to patch Cython 'async def' coroutines to have a 'tp_iter' slot,
# which makes them compatible with 'yield from' without the
# `asyncio.coroutine` decorator.
define UVLOOP_BUILD_PATCH_SCRIPT
import re

with open('uvloop/loop.c', 'rt') as f:
    src = f.read()

src = re.sub(
    r'''
    \s* offsetof\(__pyx_CoroutineObject,\s*gi_weakreflist\),
    \s* 0,
    \s* 0,
    \s* __pyx_Coroutine_methods,
    \s* __pyx_Coroutine_memberlist,
    \s* __pyx_Coroutine_getsets,
    ''',

    r'''
    offsetof(__pyx_CoroutineObject, gi_weakreflist),
    __Pyx_Coroutine_await, /* tp_iter */
    0,
    __pyx_Coroutine_methods,
    __pyx_Coroutine_memberlist,
    __pyx_Coroutine_getsets,
    ''',

    src, flags=re.X)

# Fix a segfault in Cython.
src = re.sub(
    r'''
    \s* __Pyx_Coroutine_get_qualname\(__pyx_CoroutineObject\s+\*self\)
    \s* {
    \s* Py_INCREF\(self->gi_qualname\);
    ''',

    r'''
    __Pyx_Coroutine_get_qualname(__pyx_CoroutineObject *self)
    {
        if (self->gi_qualname == NULL) { return __pyx_empty_unicode; }
        Py_INCREF(self->gi_qualname);
    ''',

    src, flags=re.X)

src = re.sub(
    r'''
    \s* __Pyx_Coroutine_get_name\(__pyx_CoroutineObject\s+\*self\)
    \s* {
    \s* Py_INCREF\(self->gi_name\);
    ''',

    r'''
    __Pyx_Coroutine_get_name(__pyx_CoroutineObject *self)
    {
        if (self->gi_name == NULL) { return __pyx_empty_unicode; }
        Py_INCREF(self->gi_name);
    ''',

    src, flags=re.X)

with open('uvloop/loop.c', 'wt') as f:
    f.write(src)
endef
export UVLOOP_BUILD_PATCH_SCRIPT
