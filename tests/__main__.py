import multiprocessing
import os.path
import sys
import unittest
import unittest.runner


def suite():
    test_loader = unittest.TestLoader()
    test_suite = test_loader.discover(os.path.dirname(__file__))
    return test_suite


if __name__ == "__main__":
    if sys.platform == "win32":
        multiprocessing.freeze_support()
    runner = unittest.runner.TextTestRunner()
    result = runner.run(suite())
    sys.exit(not result.wasSuccessful())
