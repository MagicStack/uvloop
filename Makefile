.PHONY: compile clean all distclean test test1 debug


all: clean compile


clean:
	mv uvloop/futures.c uvloop/futures.c~
	rm -fdr uvloop/*.c uvloop/*.html uvloop/*.so build *.egg-info
	mv uvloop/futures.c~ uvloop/futures.c
	find . -name '__pycache__' | xargs rm -rf


distclean: clean
	git -C vendor/libuv clean -dfX


compile: clean
	echo "DEF DEBUG = 0" > uvloop/__debug.pxi
	cython -3 -a uvloop/loop.pyx; rm uvloop/__debug.pxi
	python3 setup.py build_ext --inplace


debug: clean
	echo "DEF DEBUG = 1" > uvloop/__debug.pxi
	cython -3 -a uvloop/loop.pyx; rm uvloop/__debug.pxi
	python3 setup.py build_ext --inplace


test:
	PYTHONASYNCIODEBUG=1 python3 -m unittest discover -s tests
	python3 -m unittest discover -s tests


test1:
	python3 -m py.test -s --assert=plain -k $(filter-out $@,$(MAKECMDGOALS))


# Catch all rule (for 'make test1 smth' work without make errors)
%:
	@:
