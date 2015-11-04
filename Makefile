.PHONY: compile clean all deepclean


all: clean compile


clean:
	rm -fdr uvloop/*.c uvloop/*.html uvloop/*.so build *.egg-info
	find . -name '__pycache__' | xargs rm -rf


deepclean: clean
	git -C vendor/libuv clean -dfX


compile: clean
	cython -a uvloop/loop.pyx
	python3 setup.py build_ext --inplace
