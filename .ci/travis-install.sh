#!/bin/bash

set -e -x

if [ "${TRAVIS_OS_NAME}" == "osx" ]; then
    brew update >/dev/null
    brew upgrade pyenv
    eval "$(pyenv init -)"

    if ! (pyenv versions | grep "${PYTHON_VERSION}$"); then
        pyenv install ${PYTHON_VERSION}
    fi
    pyenv global ${PYTHON_VERSION}
    pyenv rehash

    brew install gnu-sed
    brew outdated libtool || brew upgrade libtool
    brew outdated autoconf || brew upgrade autoconf
    brew outdated automake || brew upgrade automake
fi

pip install --upgrade setuptools pip wheel
pip install -r .ci/requirements.txt
