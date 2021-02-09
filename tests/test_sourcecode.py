import os
import subprocess
import sys
import unittest


def find_uvloop_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class TestSourceCode(unittest.TestCase):

    def test_flake8(self):
        edgepath = find_uvloop_root()
        config_path = os.path.join(edgepath, '.flake8')
        if not os.path.exists(config_path):
            raise RuntimeError('could not locate .flake8 file')

        try:
            import flake8  # NoQA
        except ImportError:
            raise unittest.SkipTest('flake8 module is missing')

        for subdir in ['examples', 'uvloop', 'tests']:
            try:
                subprocess.run(
                    [sys.executable, '-m', 'flake8', '--config', config_path],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    cwd=os.path.join(edgepath, subdir))
            except subprocess.CalledProcessError as ex:
                output = ex.output.decode()
                raise AssertionError(
                    'flake8 validation failed:\n{}'.format(output)) from None

    def test_mypy(self):
        edgepath = find_uvloop_root()
        config_path = os.path.join(edgepath, 'mypy.ini')
        if not os.path.exists(config_path):
            raise RuntimeError('could not locate mypy.ini file')

        try:
            import mypy  # NoQA
        except ImportError:
            raise unittest.SkipTest('mypy moudule is missing')

        try:
            subprocess.run(
                [
                    sys.executable,
                    '-m',
                    'mypy',
                    '--config-file',
                    config_path,
                    'uvloop'
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=edgepath
            )
        except subprocess.CalledProcessError as ex:
            output = ex.output.decode()
            raise AssertionError(
                'mypy validation failed:\n{}'.format(output)) from None
