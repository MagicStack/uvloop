import os
import os.path
import re
import shutil
import subprocess
import sys
import unittest


if sys.platform in ('win32', 'cygwin', 'cli'):
    raise RuntimeError('uvloop does not support Windows at the moment')

vi = sys.version_info
if vi < (3, 5):
    raise RuntimeError('uvloop requires Python 3.5 or greater')
if vi[:2] == (3, 6):
    if vi.releaselevel == 'beta' and vi.serial < 3:
        raise RuntimeError('uvloop requires Python 3.5 or 3.6b3 or greater')


from setuptools import setup, Extension
from setuptools.command.build_ext import build_ext as build_ext
from setuptools.command.sdist import sdist as sdist


VERSION = '0.7.0'
CFLAGS = ['-O2']
LIBUV_DIR = os.path.join(os.path.dirname(__file__), 'vendor', 'libuv')
LIBUV_BUILD_DIR = os.path.join(os.path.dirname(__file__), 'build', 'libuv')


def discover_tests():
    test_loader = unittest.TestLoader()
    test_suite = test_loader.discover('tests', pattern='test_*.py')
    return test_suite


def _libuv_build_env():
    env = os.environ.copy()

    cur_cflags = env.get('CFLAGS', '')
    if not re.search('-O\d', cur_cflags):
        cur_cflags += ' -O2'

    env['CFLAGS'] = (cur_cflags + ' -fPIC ' + env.get('ARCHFLAGS', ''))

    return env


def _libuv_autogen(env):
    if not os.path.exists(os.path.join(LIBUV_DIR, 'configure')):
        subprocess.run(
            ['/bin/sh', 'autogen.sh'], cwd=LIBUV_DIR, env=env, check=True)


class uvloop_sdist(sdist):
    def run(self):
        # Make sure sdist archive contains configure
        # to avoid the dependency on autotools.
        _libuv_autogen(_libuv_build_env())
        super().run()


class uvloop_build_ext(build_ext):
    user_options = build_ext.user_options + [
        ('cython-always', None,
            'run cythonize() even if .c files are present'),
        ('cython-annotate', None,
            'Produce a colorized HTML version of the Cython source.'),
        ('cython-directives=', None,
            'Cythion compiler directives'),
        ('use-system-libuv', None,
            'Use the system provided libuv, instead of the bundled one'),
    ]

    boolean_options = build_ext.boolean_options + [
        'cython-always',
        'cython-annotate',
        'use-system-libuv',
    ]

    def initialize_options(self):
        super().initialize_options()
        self.use_system_libuv = False
        self.cython_always = False
        self.cython_annotate = None
        self.cython_directives = None

    def finalize_options(self):
        need_cythonize = self.cython_always
        cfiles = {}

        for extension in self.distribution.ext_modules:
            for i, sfile in enumerate(extension.sources):
                if sfile.endswith('.pyx'):
                    prefix, ext = os.path.splitext(sfile)
                    cfile = prefix + '.c'

                    if os.path.exists(cfile) and not self.cython_always:
                        extension.sources[i] = cfile
                    else:
                        if os.path.exists(cfile):
                            cfiles[cfile] = os.path.getmtime(cfile)
                        else:
                            cfiles[cfile] = 0
                        need_cythonize = True

        if need_cythonize:
            try:
                import Cython
            except ImportError:
                raise RuntimeError(
                    'please install Cython to compile uvloop from source')

            if Cython.__version__ < '0.24':
                raise RuntimeError(
                    'uvloop requires Cython version 0.24 or greater')

            from Cython.Build import cythonize

            directives = {}
            if self.cython_directives:
                for directive in self.cython_directives.split(','):
                    k, _, v = directive.partition('=')
                    if v.lower() == 'false':
                        v = False
                    if v.lower() == 'true':
                        v = True

                    directives[k] = v

            self.distribution.ext_modules[:] = cythonize(
                self.distribution.ext_modules,
                compiler_directives=directives,
                annotate=self.cython_annotate)

            for cfile, timestamp in cfiles.items():
                if os.path.getmtime(cfile) != timestamp:
                    # The file was recompiled, patch
                    self._patch_cfile(cfile)

        super().finalize_options()

    def _patch_cfile(self, cfile):
        # Patch Cython 'async def' coroutines to have a 'tp_iter'
        # slot, which makes them compatible with 'yield from' without
        # the `asyncio.coroutine` decorator.

        with open(cfile, 'rt') as f:
            src = f.read()

        src = re.sub(
            r'''
            \s* offsetof\(__pyx_CoroutineObject,\s*gi_weakreflist\),
            \s* 0,
            \s* 0,
            \s* __pyx_Coroutine_methods,
            \s* __pyx_Coroutine_memberlist,
            \s* __pyx_Coroutine_getsets,
            ''',

            r'''
            offsetof(__pyx_CoroutineObject, gi_weakreflist),
            __Pyx_Coroutine_await, /* tp_iter */
            (iternextfunc) __Pyx_Generator_Next, /* tp_iternext */
            __pyx_Coroutine_methods,
            __pyx_Coroutine_memberlist,
            __pyx_Coroutine_getsets,
            ''',

            src, flags=re.X)

        # Fix a segfault in Cython.
        src = re.sub(
            r'''
            \s* __Pyx_Coroutine_get_qualname\(__pyx_CoroutineObject\s+\*self\)
            \s* {
            \s* Py_INCREF\(self->gi_qualname\);
            ''',

            r'''
            __Pyx_Coroutine_get_qualname(__pyx_CoroutineObject *self)
            {
                if (self->gi_qualname == NULL) { return __pyx_empty_unicode; }
                Py_INCREF(self->gi_qualname);
            ''',

            src, flags=re.X)

        src = re.sub(
            r'''
            \s* __Pyx_Coroutine_get_name\(__pyx_CoroutineObject\s+\*self\)
            \s* {
            \s* Py_INCREF\(self->gi_name\);
            ''',

            r'''
            __Pyx_Coroutine_get_name(__pyx_CoroutineObject *self)
            {
                if (self->gi_name == NULL) { return __pyx_empty_unicode; }
                Py_INCREF(self->gi_name);
            ''',

            src, flags=re.X)

        with open(cfile, 'wt') as f:
            f.write(src)

    def build_libuv(self):
        env = _libuv_build_env()

        # Make sure configure and friends are present in case
        # we are building from a git checkout.
        _libuv_autogen(env)

        # Copy the libuv tree to build/ so that its build
        # products don't pollute sdist accidentally.
        if os.path.exists(LIBUV_BUILD_DIR):
            shutil.rmtree(LIBUV_BUILD_DIR)
        shutil.copytree(LIBUV_DIR, LIBUV_BUILD_DIR)

        # Sometimes pip fails to preserve the timestamps correctly,
        # in which case, make will try to run autotools again.
        subprocess.run(
            ['touch', 'configure.ac', 'aclocal.m4', 'configure',
             'Makefile.am', 'Makefile.in'],
            cwd=LIBUV_BUILD_DIR, env=env, check=True)

        subprocess.run(
            ['./configure'],
            cwd=LIBUV_BUILD_DIR, env=env, check=True)

        j_flag = '-j{}'.format(os.cpu_count() or 1)
        c_flag = "CFLAGS={}".format(env['CFLAGS'])
        subprocess.run(
            ['make', j_flag, c_flag],
            cwd=LIBUV_BUILD_DIR, env=env, check=True)

    def build_extensions(self):
        if self.use_system_libuv:
            self.compiler.add_library('uv')

            if sys.platform == 'darwin' and \
                    os.path.exists('/opt/local/include'):
                # Support macports on Mac OS X.
                self.compiler.add_include_dir('/opt/local/include')
        else:
            libuv_lib = os.path.join(LIBUV_BUILD_DIR, '.libs', 'libuv.a')
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
        elif sys.platform.startswith('sunos'):
            self.compiler.add_library('kstat')

        super().build_extensions()


with open(os.path.join(os.path.dirname(__file__), 'README.rst')) as f:
    readme = f.read()


setup(
    name='uvloop',
    description='Fast implementation of asyncio event loop on top of libuv',
    long_description=readme,
    url='http://github.com/MagicStack/uvloop',
    license='MIT',
    author='Yury Selivanov',
    author_email='yury@magic.io',
    platforms=['*nix'],
    version=VERSION,
    packages=['uvloop'],
    cmdclass={
        'sdist': uvloop_sdist,
        'build_ext': uvloop_build_ext
    },
    ext_modules=[
        Extension(
            "uvloop.loop",
            sources=[
                "uvloop/loop.pyx",
            ],
            extra_compile_args=CFLAGS
        ),
    ],
    classifiers=[
        'Development Status :: 4 - Beta',
        'Programming Language :: Python :: 3 :: Only',
        'Programming Language :: Python :: 3.5',
        'Programming Language :: Python :: 3.6',
        'License :: OSI Approved :: Apache Software License',
        'License :: OSI Approved :: MIT License',
        'Intended Audience :: Developers',
    ],
    provides=['uvloop'],
    include_package_data=True,
    test_suite='setup.discover_tests'
)
