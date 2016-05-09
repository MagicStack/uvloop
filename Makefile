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
	python setup.py build_ext --inplace


debug: clean
	echo "DEF DEBUG = 1" > uvloop/__debug.pxi
	cython -3 -a -p uvloop/loop.pyx; rm uvloop/__debug.*
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
