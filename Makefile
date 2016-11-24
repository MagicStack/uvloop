.PHONY: _default clean clean-libuv distclean compile debug docs test release


PYTHON ?= python


_default: compile


clean:
	rm -fr dist/ doc/_build/ *.egg-info build/ uvloop/loop.*.pyd
	rm -fr build/lib.* build/temp.*
	rm -fr uvloop/*.c uvloop/*.html uvloop/*.so
	rm -fr uvloop/handles/*.html uvloop/includes/*.html
	find . -name '__pycache__' | xargs rm -rf


clean-libuv:
	(cd vendor/libuv; git clean -dfX)


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


release: distclean compile test
	$(PYTHON) setup.py sdist bdist_wheel upload
