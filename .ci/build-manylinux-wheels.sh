#!/bin/bash

set -e -x

# Compile wheels
PYTHON="/opt/python/${PYTHON_VERSION}/bin/python"
PIP="/opt/python/${PYTHON_VERSION}/bin/pip"
${PIP} install --upgrade pip wheel
${PIP} install --upgrade setuptools
${PIP} install -r /io/.ci/requirements.txt
make -C /io/ PYTHON="${PYTHON}"
${PIP} wheel /io/ -w /io/dist/

# Bundle external shared libraries into the wheels.
for whl in /io/dist/*.whl; do
    auditwheel repair $whl -w /io/dist/
    rm /io/dist/*-linux_*.whl
done

PYTHON="/opt/python/${PYTHON_VERSION}/bin/python"
PIP="/opt/python/${PYTHON_VERSION}/bin/pip"
${PIP} install ${PYMODULE} --no-index -f file:///io/dist
rm -rf /io/tests/__pycache__
make -C /io/ PYTHON="${PYTHON}" test
rm -rf /io/tests/__pycache__
