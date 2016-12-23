#!/usr/bin/env python3


import argparse
import sys
import xmlrpc.client


def main():
    parser = argparse.ArgumentParser(description='PyPI package checker')
    parser.add_argument('package_name', metavar='PACKAGE-NAME')

    parser.add_argument(
        '--pypi-index-url',
        help=('PyPI index URL.'),
        default='https://pypi.python.org/pypi')

    args = parser.parse_args()

    pypi = xmlrpc.client.ServerProxy(args.pypi_index_url)
    releases = pypi.package_releases(args.package_name)

    if releases:
        print(next(iter(sorted(releases, reverse=True))))

    return 0


if __name__ == '__main__':
    sys.exit(main())
