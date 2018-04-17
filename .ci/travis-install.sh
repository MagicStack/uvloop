#!/bin/bash

set -e -x

if [ "${TRAVIS_OS_NAME}" == "osx" ]; then
    git clone --depth 1 https://github.com/yyuu/pyenv.git ~/.pyenv
    PYENV_ROOT="$HOME/.pyenv"
    PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"

    if ! (pyenv versions | grep "${PYTHON_VERSION}$"); then
        pyenv install ${PYTHON_VERSION}
    fi
    pyenv global ${PYTHON_VERSION}
    pyenv rehash

    brew update

    brew install gnu-sed --with-default-names
    brew outdated libtool || brew upgrade libtool
    brew outdated autoconf || brew upgrade autoconf --with-default-names
    brew outdated automake || brew upgrade automake --with-default-names

    # Pined to 9.0.X till following issues are addressed
    # https://github.com/pypa/pip/issues/5240
    # https://github.com/pyenv/pyenv/issues/1141
    pip install --upgrade pip~=9.0.0
else
    pip install --upgrade pip
fi

pip install --upgrade wheel
pip install --upgrade setuptools
pip install -r .ci/requirements.txt
