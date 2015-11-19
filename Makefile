.PHONY: compile clean all distclean test test1


all: clean compile


clean:
	mv uvloop/futures.c uvloop/futures.c~
	rm -fdr uvloop/*.c uvloop/*.html uvloop/*.so build *.egg-info
	mv uvloop/futures.c~ uvloop/futures.c
	find . -name '__pycache__' | xargs rm -rf


distclean: clean
	git -C vendor/libuv clean -dfX


compile: clean
	cython -a uvloop/loop.pyx
	python3 setup.py build_ext --inplace


test:
	python3 -m unittest discover -s tests -v


test1:
	python3 -m py.test -s --assert=plain -k $(filter-out $@,$(MAKECMDGOALS))
