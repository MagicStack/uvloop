.PHONY: compile clean all distclean test debug sdist clean-libuv
.PHONY: release sdist-libuv docs


PYTHON ?= python


all: compile


clean:
	rm -fr dist/ doc/_build/
	rm -fr uvloop/*.c uvloop/*.html uvloop/*.so build *.egg-info
	rm -fr uvloop/handles/*.html uvloop/includes/*.html
	find . -name '__pycache__' | xargs rm -rf


clean-libuv:
	(cd vendor/libuv; git clean -dfX)


sdist-libuv: clean-libuv
	/bin/sh vendor/libuv/autogen.sh


distclean: clean clean-libuv


compile: clean
	$(PYTHON) setup.py build_ext --inplace --cython-always


debug: clean
	$(PYTHON) setup.py build_ext --inplace --debug \
		--cython-always \
		--cython-annotate \
		--cython-directives="linetrace=True" \
		--define UVLOOP_DEBUG,CYTHON_TRACE,CYTHON_TRACE_NOGIL


docs: compile
	cd docs && $(PYTHON) -m sphinx -a -b html . _build/html


test:
	PYTHONASYNCIODEBUG=1 $(PYTHON) -m unittest discover -s tests
	$(PYTHON) -m unittest discover -s tests


sdist: clean compile test sdist-libuv
	$(PYTHON) setup.py sdist


# Don't change "clean" to "distclean"!  Otherwise "clean-libuv" will
# only be called once, which will produce a broken sdist.
release: clean compile test sdist-libuv
	$(PYTHON) setup.py sdist bdist_wheel upload
