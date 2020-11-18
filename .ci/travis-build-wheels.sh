#!/bin/bash

set -e -x


if [[ "${TRAVIS_BRANCH}" != "releases" || "${BUILD}" != *wheels* ]]; then
    # Not a release
    exit 0
fi


if [ "${TRAVIS_OS_NAME}" == "osx" ]; then
    PYENV_ROOT="$HOME/.pyenv"
    PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
    pyenv local ${PYTHON_VERSION}
fi

PACKAGE_VERSION=$(python ".ci/package-version.py")
PYPI_VERSION=$(python ".ci/pypi-check.py" "${PYMODULE}")

if [ "${PACKAGE_VERSION}" == "${PYPI_VERSION}" ]; then
    echo "${PYMODULE}-${PACKAGE_VERSION} is already published on PyPI"
    exit 1
fi


pushd $(dirname $0) > /dev/null
_root=$(dirname $(pwd -P))
popd > /dev/null


_upload_wheels() {
    python "${_root}/.ci/s3-upload.py" "${_root}/dist"/*.whl
    sudo rm -rf "${_root}/dist"/*.whl
}


if [ "${TRAVIS_OS_NAME}" == "linux" ]; then
    for pyver in ${RELEASE_PYTHON_VERSIONS}; do
        ML_PYTHON_VERSION=$(python3 -c \
            "print('cp{maj}{min}-cp{maj}{min}{s}'.format( \
                   maj='${pyver}'.split('.')[0], \
                   min='${pyver}'.split('.')[1],
                   s='m' if tuple('${pyver}'.split('.')) < ('3', '8') \
                     else ''))")

      if [ "${TRAVIS_CPU_ARCH}" == "arm64" ] ; then
          arch = aarch64;
          ML_IMAGE="quay.io/pypa/manylinux2014_${arch}"
      elif [ "${TRAVIS_CPU_ARCH}" == "x86_64" ] ; then
          arch = x86_64;
          ML_IMAGE="quay.io/pypa/manylinux2010_${arch}"
      fi
      docker pull "${ML_IMAGE}"
            docker run --rm \
                -v "${_root}":/io \
                -e "PYARCH=${arch}" \
                -e "PYMODULE=${PYMODULE}" \
                -e "PYTHON_VERSION=${ML_PYTHON_VERSION}" \
                "${ML_IMAGE}" /io/.ci/build-manylinux-wheels.sh

            _upload_wheels
    done

elif [ "${TRAVIS_OS_NAME}" == "osx" ]; then
    make clean && make -C "${_root}"
    pip wheel "${_root}" -w "${_root}/dist/"

    pip install ${PYMODULE} --no-index -f "file:///${_root}/dist"
    pushd / >/dev/null
    make -C "${_root}" testinstalled
    popd >/dev/null

    _upload_wheels

else
    echo "Cannot build on ${TRAVIS_OS_NAME}."
fi
