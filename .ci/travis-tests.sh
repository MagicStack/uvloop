#!/bin/bash

set -e -x

if [[ "${BUILD}" != *tests* ]]; then
    echo "Skipping tests."
    exit 0
fi

if [ "${TRAVIS_OS_NAME}" == "osx" ]; then
    PYENV_ROOT="$HOME/.pyenv"
    PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
fi

make distclean && make && make test
make distclean && make debug && make test
