import os
import os.path
import re
import shutil
import subprocess
import sys


from setuptools import setup, Extension
from setuptools.command.build_ext import build_ext as build_ext
from setuptools.command.sdist import sdist as sdist


if sys.platform in ('win32', 'cygwin', 'cli'):
    raise RuntimeError('uvloop does not support Windows at the moment')

vi = sys.version_info
if vi < (3, 5):
    raise RuntimeError('uvloop requires Python 3.5 or greater')
if vi[:2] == (3, 6):
    if vi.releaselevel == 'beta' and vi.serial < 3:
        raise RuntimeError('uvloop requires Python 3.5 or 3.6b3 or greater')


CFLAGS = ['-O2']
LIBUV_DIR = os.path.join(os.path.dirname(__file__), 'vendor', 'libuv')
LIBUV_BUILD_DIR = os.path.join(os.path.dirname(__file__), 'build', 'libuv')


def _libuv_build_env():
    env = os.environ.copy()

    cur_cflags = env.get('CFLAGS', '')
    if not re.search(r'-O\d', cur_cflags):
        cur_cflags += ' -O2'

    env['CFLAGS'] = (cur_cflags + ' -fPIC ' + env.get('ARCHFLAGS', ''))

    return env


def _libuv_autogen(env):
    if os.path.exists(os.path.join(LIBUV_DIR, 'configure')):
        # No need to use autogen, the configure script is there.
        return

    if not os.path.exists(os.path.join(LIBUV_DIR, 'autogen.sh')):
        raise RuntimeError(
            'the libuv submodule has not been checked out; '
            'try running "git submodule init; git submodule update"')

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
        # initialize_options() may be called multiple times on the
        # same command object, so make sure not to override previously
        # set options.
        if getattr(self, '_initialized', False):
            return

        super().initialize_options()
        self.use_system_libuv = False
        self.cython_always = False
        self.cython_annotate = None
        self.cython_directives = None

    def finalize_options(self):
        # finalize_options() may be called multiple times on the
        # same command object, so make sure not to override previously
        # set options.
        if getattr(self, '_initialized', False):
            return

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

            if Cython.__version__ < '0.28':
                raise RuntimeError(
                    'uvloop requires Cython version 0.28 or greater')

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

        super().finalize_options()

        self._initialized = True

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

        if 'LIBUV_CONFIGURE_HOST' in env:
            cmd = ['./configure', '--host=' + env['LIBUV_CONFIGURE_HOST']]
        else:
            cmd = ['./configure']
        subprocess.run(
            cmd,
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
        elif sys.platform.startswith(('freebsd', 'dragonfly')):
            self.compiler.add_library('kvm')
        elif sys.platform.startswith('sunos'):
            self.compiler.add_library('kstat')

        self.compiler.add_library('pthread')

        super().build_extensions()


with open(os.path.join(os.path.dirname(__file__), 'README.rst')) as f:
    readme = f.read()


with open(os.path.join(
        os.path.dirname(__file__), 'uvloop', '__init__.py')) as f:
    for line in f:
        if line.startswith('__version__ ='):
            _, _, version = line.partition('=')
            VERSION = version.strip(" \n'\"")
            break
    else:
        raise RuntimeError(
            'unable to read the version from uvloop/__init__.py')


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
        'Development Status :: 5 - Production/Stable',
        'Framework :: AsyncIO',
        'Programming Language :: Python :: 3 :: Only',
        'Programming Language :: Python :: 3.5',
        'Programming Language :: Python :: 3.6',
        'Programming Language :: Python :: 3.7',
        'License :: OSI Approved :: Apache Software License',
        'License :: OSI Approved :: MIT License',
        'Intended Audience :: Developers',
    ],
    provides=['uvloop'],
    include_package_data=True,
    test_suite='tests.suite'
)
