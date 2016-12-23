#!/bin/bash

set -e -x


if [ -z "${TRAVIS_TAG}" ]; then
    # Not a release
    exit 0
fi


PACKAGE_VERSION=$(python ".ci/package-version.py")
PYPI_VERSION=$(python ".ci/pypi-check.py" "${PYMODULE}")

if [ "${PACKAGE_VERSION}" == "${PYPI_VERSION}" ]; then
    echo "${PYMODULE}-${PACKAGE_VERSION} is already published on PyPI"
    exit 0
fi

# Check if all expected wheels have been built and uploaded.
release_platforms=(
    "macosx_10_??_x86_64"
    "manylinux1_i686"
    "manylinux1_x86_64"
)

P="${PYMODULE}-${PACKAGE_VERSION}"
expected_wheels=()

for pyver in ${RELEASE_PYTHON_VERSIONS}; do
    pyver="${pyver//./}"
    abitag="cp${pyver}-cp${pyver}m"
    for plat in "${release_platforms[@]}"; do
        expected_wheels+=("${P}-${abitag}-${plat}.whl")
    done
done

rm -rf dist/*.whl dist/*.tar.*
python setup.py sdist
python ".ci/s3-download-release.py" --destdir=dist/ "${P}"

_file_exists() { [[ -f $1 ]]; }

for distfile in "${expected_wheels[@]}"; do
    if ! _file_exists dist/${distfile}; then
        echo "Expected wheel ${distfile} not found."
        exit 1
    fi
done

python -m twine upload dist/*.whl dist/*.tar.*
