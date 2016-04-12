.PHONY: compile clean all distclean test debug sdist clean-libuv sdist-upload


all: clean compile


clean:
	rm -fdr uvloop/*.c uvloop/*.html uvloop/*.so build *.egg-info
	rm -fdr uvloop/handles/*.html uvloop/includes/*.html
	find . -name '__pycache__' | xargs rm -rf


clean-libuv:
	git -C vendor/libuv clean -dfX


distclean: clean clean-libuv


compile: clean
	echo "DEF DEBUG = 0" > uvloop/__debug.pxi
	cython -3 uvloop/loop.pyx; rm uvloop/__debug.*
	python3 setup.py build_ext --inplace


debug: clean
	echo "DEF DEBUG = 1" > uvloop/__debug.pxi
	cython -3 -a -p uvloop/loop.pyx; rm uvloop/__debug.*
	python3 setup.py build_ext --inplace


test:
	PYTHONASYNCIODEBUG=1 python3 -m unittest discover -s tests
	python3 -m unittest discover -s tests


sdist: clean compile test clean-libuv
	python3 setup.py sdist


sdist-upload: clean compile test clean-libuv
	python3 setup.py sdist upload
