.PHONY: _default clean clean-libuv distclean compile debug docs test testinstalled release setup-build ci-clean


PYTHON ?= python
ROOT = $(dir $(realpath $(firstword $(MAKEFILE_LIST))))


_default: compile


clean:
	rm -fr dist/ doc/_build/ *.egg-info uvloop/loop.*.pyd
	rm -fr uvloop/*.c uvloop/*.html uvloop/*.so
	rm -fr uvloop/handles/*.html uvloop/includes/*.html
	find . -name '__pycache__' | xargs rm -rf


ci-clean: clean
	rm -fr build/lib.* build/temp.* build/libuv


clean-libuv:
	(cd vendor/libuv; git clean -dfX)


distclean: clean clean-libuv
	rm -fr build/


setup-build:
	$(PYTHON) setup.py build_ext --inplace --cython-always


compile: clean setup-build


debug: clean
	$(PYTHON) setup.py build_ext --inplace --debug \
		--cython-always \
		--cython-annotate \
		--cython-directives="linetrace=True" \
		--define UVLOOP_DEBUG,CYTHON_TRACE,CYTHON_TRACE_NOGIL


docs:
	$(PYTHON) setup.py build_ext --inplace build_sphinx


test:
	PYTHONASYNCIODEBUG=1 $(PYTHON) -m unittest -v tests.suite
	$(PYTHON) -m unittest -v tests.suite


testinstalled:
	cd "$${HOME}" && $(PYTHON) $(ROOT)/tests/__init__.py
