#!/bin/bash

set -e -x


if [ -z "${TRAVIS_TAG}" ]; then
    # Not a release
    exit 0
fi

release_level=$(python -c 'import sys; print(sys.version_info.releaselevel)')
if [ "${release_level}" != "final" ]; then
    exit 0
fi


pushd $(dirname $0) > /dev/null
_root=$(dirname $(pwd -P))
popd > /dev/null


_upload_wheels() {
    set +x
    echo python -m twine upload  \
        --username "${PYPI_USER}" --password "<secret>" \
        "${_root}/dist"/*.whl
    python -m twine upload  \
        --username "${PYPI_USER}" --password "${PYPI_PASSWD}" \
        "${_root}/dist"/*.whl

    set -x
    sudo rm -rf "${_root}/dist"/*.whl
}


# Release build
if [ "${TRAVIS_OS_NAME}" == "linux" ]; then
    docker pull quay.io/pypa/manylinux1_x86_64
    docker run --rm \
        -v "${_root}":/io -e "PYMODULE=${PYMODULE}" \
        quay.io/pypa/manylinux1_x86_64 \
            /io/.ci/build-manylinux-wheels.sh

    _upload_wheels

    docker pull quay.io/pypa/manylinux1_i686
    docker run --rm \
        -v "${_root}":/io -e "PYMODULE=${PYMODULE}" \
        quay.io/pypa/manylinux1_i686 linux32 \
            /io/.ci/build-manylinux-wheels.sh

    _upload_wheels

elif [ "${TRAVIS_OS_NAME}" == "osx" ]; then
    eval "$(pyenv init -)"
    pyenv local ${PYTHON_VERSION}

    make -C "${_root}" distclean
    make -C "${_root}"
    pip wheel "${_root}" -w "${_root}/dist/"

    pip install ${PYMODULE} --no-index -f "file:///${_root}/dist"
    pushd / >/dev/null
    make -C "${_root}" test
    popd >/dev/null

    _upload_wheels

else
    echo "Cannot build on ${TRAVIS_OS_NAME}."
fi
