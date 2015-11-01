.PHONY: compile clean


clean:
	git -C vendor/libuv clean -dfX
	rm -fdr uvloop/uvloop.c uvloop/uvloop.html build *.egg-info


compile:
	cython uvloop/uvloop.pyx
	python3 setup.py build_ext --inplace


