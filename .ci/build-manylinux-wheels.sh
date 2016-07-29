#!/bin/bash

set -e -x

yum update -y
yum install -y libtool autoconf automake

PYTHON_VERSIONS="cp35-cp35m"

# Compile wheels
for PYTHON_VERSION in ${PYTHON_VERSIONS}; do
    PYTHON="/opt/python/${PYTHON_VERSION}/bin/python"
    PIP="/opt/python/${PYTHON_VERSION}/bin/pip"
    ${PIP} install --upgrade pip wheel
    ${PIP} install --upgrade setuptools
    ${PIP} install -r /io/.ci/requirements.txt
    make -C /io/ PYTHON="${PYTHON}" distclean
    make -C /io/ PYTHON="${PYTHON}"
    ${PIP} wheel /io/ -w /io/dist/
done

#Bundle external shared libraries into the wheels.
for whl in /io/dist/*.whl; do
    auditwheel repair $whl -w /io/dist/
    rm /io/dist/*-linux_*.whl
done

for PYTHON_VERSION in ${PYTHON_VERSIONS}; do
    PYTHON="/opt/python/${PYTHON_VERSION}/bin/python"
    PIP="/opt/python/${PYTHON_VERSION}/bin/pip"
    ${PIP} install ${PYMODULE} --no-index -f file:///io/dist
    rm -rf /io/tests/__pycache__
    make -C /io/ PYTHON="${PYTHON}" test
    rm -rf /io/tests/__pycache__
done
