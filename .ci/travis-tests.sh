#!/bin/bash

set -e -x

if [[ "${BUILD}" != *tests* ]]; then
    echo "Skipping tests."
    exit 0
fi

if [ "${PYENV}" == "true" ]; then
    PYENV_ROOT="$HOME/.pyenv"
    PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
    pyenv global ${PYTHON_VERSION}
fi

python --version

make distclean && make && make test
make distclean && make debug && make test
