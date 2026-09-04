import subprocess
import sys
# Workaround file for Makefile for passing --debug on
# verisons that have a debuggable system as windows does not 
# have a debug system like it. And workflows can't seem
# to find where those *_d.lib binaries are...

CMD = ["python", "setup.py", "build_ext", "--inplace", \
		"--cython-always",
		"--cython-annotate",
		"-DUVLOOP_DEBUG","-DCYTHON_TRACE","-DCYTHON_TRACE_NOGIL"]

if sys.platform != "win32":
    CMD.append("--debug", "--cython-directives=\"linetrace=True\"")

if __name__ == "__main__":
    # Execute and wait for it to finish
    sys.exit(subprocess.check_call(CMD, shell=sys.platform == "win32"))
    pass
