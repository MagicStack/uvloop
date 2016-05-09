import os
import subprocess
import sys


if sys.platform in ('win32', 'cygwin', 'cli'):
    raise RuntimeError('uvloop does not support Windows at the moment')
if sys.version_info < (3, 5):
    raise RuntimeError('uvloop requires Python 3.5 or greater')


from setuptools import setup, Extension
from setuptools.command.build_ext import build_ext


LIBUV_DIR = os.path.join(os.path.dirname(__file__), 'vendor', 'libuv')


class libuv_build_ext(build_ext):
    def build_libuv(self):
        env = os.environ.copy()

        env['CFLAGS'] = ('-fPIC ' +
                         env.get('CFLAGS', '-O2') +
                         ' ' +
                         env.get('ARCHFLAGS', ''))

        j_flag = '-j{}'.format(os.cpu_count() or 1)

        if not os.path.exists(os.path.join(LIBUV_DIR, 'configure')):
            subprocess.run(['/bin/sh', 'autogen.sh'], cwd=LIBUV_DIR, env=env,
                           check=True)

        subprocess.run(['./configure'], cwd=LIBUV_DIR, env=env, check=True)
        subprocess.run(['make', j_flag], cwd=LIBUV_DIR, env=env, check=True)

    def build_extensions(self):
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
    version='0.4.15',
    packages=['uvloop'],
    cmdclass={'build_ext': libuv_build_ext},
    ext_modules=[
        Extension(
            "uvloop.loop",
            sources=[
                "uvloop/loop.c",
            ]
        ),
    ],
    classifiers=[
        'Development Status :: 4 - Beta',
        'Programming Language :: Python :: 3.5',
        'License :: OSI Approved :: MIT License',
        'Intended Audience :: Developers',
    ],
    provides=['uvloop'],
    include_package_data=True
)
