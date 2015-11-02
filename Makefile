.PHONY: compile clean


clean:
	git -C vendor/libuv clean -dfX
	rm -fdr uvloop/*.c uvloop/*.html build *.egg-info


compile:
	cython -a uvloop/loop.pyx uvloop/idle.pyx uvloop/signal.pyx
	python3 setup.py build_ext --inplace


