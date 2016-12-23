#!/usr/bin/env python3


import os.path
import sys


def main():
    setup_py = os.path.join(os.path.dirname(os.path.dirname(__file__)),
                            'setup.py')

    with open(setup_py, 'r') as f:
        for line in f:
            if line.startswith('VERSION ='):
                _, _, version = line.partition('=')
                print(version.strip(" \n'\""))
                return 0

    print('could not find package version in setup.py', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
