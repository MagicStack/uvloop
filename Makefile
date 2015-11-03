.PHONY: compile clean


clean:
	git -C vendor/libuv clean -dfX
	rm -fdr uvloop/*.c uvloop/*.html uvloop/*.so build *.egg-info
	find . -name '__pycache__' | xargs rm -rf


compile:
	cython -a uvloop/loop.pyx uvloop/handle.pyx \
              uvloop/idle.pyx uvloop/signal.pyx \
			  uvloop/async_.pyx uvloop/timer.pyx

	python3 setup.py build_ext --inplace
