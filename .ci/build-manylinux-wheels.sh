#!/bin/bash

set -e -x

# Compile wheels
PYTHON="/opt/python/${PYTHON_VERSION}/bin/python"
PIP="/opt/python/${PYTHON_VERSION}/bin/pip"
${PIP} install -r /io/.ci/requirements.txt
make -C /io/ PYTHON="${PYTHON}" ci-clean compile
${PIP} wheel /io/ -w /io/dist/

# Bundle external shared libraries into the wheels.
for whl in /io/dist/*.whl; do
    if [ "${PYARCH}" == "aarch64" ] ; then
	PLAT="manylinux2014_${PYARCH}"
    else
	PLAT="manylinux2010_${PYARCH}"
    fi
    auditwheel repair --plat="${PLAT}" $whl -w /io/dist/
    rm /io/dist/*-linux_*.whl
done

PYTHON="/opt/python/${PYTHON_VERSION}/bin/python"
PIP="/opt/python/${PYTHON_VERSION}/bin/pip"
${PIP} install ${PYMODULE} --no-index -f file:///io/dist
rm -rf /io/tests/__pycache__
make -C /io/ PYTHON="${PYTHON}" testinstalled
rm -rf /io/tests/__pycache__
