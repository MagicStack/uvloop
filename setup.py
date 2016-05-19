import os
import re
import subprocess
import sys
import unittest


if sys.platform in ('win32', 'cygwin', 'cli'):
    raise RuntimeError('uvloop does not support Windows at the moment')
if sys.version_info < (3, 5):
    raise RuntimeError('uvloop requires Python 3.5 or greater')


from setuptools import setup, Extension
from setuptools.command.build_ext import build_ext


LIBUV_DIR = os.path.join(os.path.dirname(__file__), 'vendor', 'libuv')


def discover_tests():
    test_loader = unittest.TestLoader()
    test_suite = test_loader.discover('tests', pattern='test_*.py')
    return test_suite


class libuv_build_ext(build_ext):
    build_ext.user_options.extend([
        ("use-system-libuv", None,
         "Use the system provided libuv, instead of the bundled one")
    ])

    build_ext.boolean_options.extend(["use-system-libuv"])

    def initialize_options(self):
        build_ext.initialize_options(self)
        if getattr(self, 'use_system_libuv', None) is None:
            self.use_system_libuv = 0

    def build_libuv(self):
        env = os.environ.copy()

        cur_cflags = env.get('CFLAGS', '')
        if not re.search('-O\d', cur_cflags):
            cur_cflags += ' -O2'

        env['CFLAGS'] = (cur_cflags + ' -fPIC' + env.get('ARCHFLAGS', ''))

        j_flag = '-j{}'.format(os.cpu_count() or 1)

        if not os.path.exists(os.path.join(LIBUV_DIR, 'configure')):
            subprocess.run(['/bin/sh', 'autogen.sh'], cwd=LIBUV_DIR, env=env,
                           check=True)

        # Sometimes pip fails to preserve the timestamps correctly,
        # in which case, make will try to run autotools again.
        subprocess.run(['touch', 'configure.ac', 'aclocal.m4',
                        'configure', 'Makefile.am', 'Makefile.in'],
                       cwd=LIBUV_DIR, env=env, check=True)

        subprocess.run(['./configure'], cwd=LIBUV_DIR, env=env, check=True)

        c_flag = "CFLAGS={}".format(env['CFLAGS'])
        subprocess.run(['make', j_flag, c_flag],
                       cwd=LIBUV_DIR, env=env, check=True)

    def build_extensions(self):
        if self.use_system_libuv:
            self.compiler.add_library('uv')

            if sys.platform == 'darwin' and \
                    os.path.exists('/opt/local/include'):
                # Support macports on Mac OS X.
                self.compiler.add_include_dir('/opt/local/include')
        else:
            libuv_lib = os.path.join(LIBUV_DIR, '.libs', 'libuv.a')
            if not os.path.exists(libuv_lib):
                self.build_libuv()
            if not os.path.exists(libuv_lib):
                raise RuntimeError('failed to build libuv')

            self.extensions[-1].extra_objects.extend([libuv_lib])
            self.compiler.add_include_dir(os.path.join(LIBUV_DIR, 'include'))

        if sys.platform.startswith('linux'):
            self.compiler.add_library('rt')
        elif sys.platform.startswith('freebsd'):
            self.compiler.add_library('kvm')

        super().build_extensions()


setup(
    name='uvloop',
    description='Fast implementation of asyncio event loop on top of libuv',
    url='http://github.com/MagicStack/uvloop',
    license='MIT',
    author='Yury Selivanov',
    author_email='yury@magic.io',
    platforms=['*nix'],
    version='0.4.25',
    packages=['uvloop'],
    cmdclass={'build_ext': libuv_build_ext},
    ext_modules=[
        Extension(
            "uvloop.loop",
            sources=[
                "uvloop/loop.c",
            ],
            extra_compile_args=['-O2']
        ),
    ],
    classifiers=[
        'Development Status :: 4 - Beta',
        'Programming Language :: Python :: 3.5',
        'License :: OSI Approved :: MIT License',
        'Intended Audience :: Developers',
    ],
    provides=['uvloop'],
    include_package_data=True,
    test_suite='setup.discover_tests'
)
