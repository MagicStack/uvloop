.PHONY: compile clean all distclean test debug


all: clean compile


clean:
	rm -fdr uvloop/*.c uvloop/*.html uvloop/*.so build *.egg-info
	find . -name '__pycache__' | xargs rm -rf


distclean: clean
	git -C vendor/libuv clean -dfX


compile: clean
	echo "DEF DEBUG = 0" > uvloop/__debug.pxi
	cython -3 uvloop/loop.pyx; rm uvloop/__debug.*
	python3 setup.py build_ext --inplace


debug: clean
	echo "DEF DEBUG = 1" > uvloop/__debug.pxi
	cython -3 -a uvloop/loop.pyx; rm uvloop/__debug.*
	python3 setup.py build_ext --inplace


test:
	PYTHONASYNCIODEBUG=1 python3 -m unittest discover -s tests
	python3 -m unittest discover -s tests
