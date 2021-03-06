#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Usage:
#   docker run --rm -v $PWD:/io arrow-base-x86_64 /io/build_arrow.sh

# Build upon the scripts in https://github.com/matthew-brett/manylinux-builds
# * Copyright (c) 2013-2016, Matt Terry and Matthew Brett (BSD 2-clause)

# Build different python versions with various unicode widths
PYTHON_VERSIONS="${PYTHON_VERSIONS:-2.7,16 2.7,32 3.5,16 3.6,16 3.7,16}"

source /multibuild/manylinux_utils.sh

# Quit on failure
set -e

cd /arrow/python

# PyArrow build configuration
export PYARROW_BUILD_TYPE='release'
export PYARROW_CMAKE_GENERATOR='Ninja'
export PYARROW_WITH_ORC=1
export PYARROW_WITH_PARQUET=1
export PYARROW_WITH_PLASMA=1
export PYARROW_BUNDLE_ARROW_CPP=1
export PYARROW_BUNDLE_BOOST=1
export PYARROW_BOOST_NAMESPACE=arrow_boost
export PKG_CONFIG_PATH=/arrow-dist/lib/pkgconfig

export PYARROW_CMAKE_OPTIONS='-DTHRIFT_HOME=/usr -DBoost_NAMESPACE=arrow_boost -DBOOST_ROOT=/arrow_boost_dist'
# Ensure the target directory exists
mkdir -p /io/dist

for PYTHON_TUPLE in ${PYTHON_VERSIONS}; do
    IFS=","
    set -- $PYTHON_TUPLE;
    PYTHON=$1
    U_WIDTH=$2
    CPYTHON_PATH="$(cpython_path $PYTHON ${U_WIDTH})"
    PYTHON_INTERPRETER="${CPYTHON_PATH}/bin/python"
    PIP="${CPYTHON_PATH}/bin/pip"
    PATH="$PATH:${CPYTHON_PATH}"

    if [ $PYTHON != "2.7" ]; then
      # Gandiva is not supported on Python 2.7
      export PYARROW_WITH_GANDIVA=1
      export BUILD_ARROW_GANDIVA=ON
    else
      export PYARROW_WITH_GANDIVA=0
      export BUILD_ARROW_GANDIVA=OFF
    fi

    # TensorFlow is not supported for Python 2.7 with unicode width 16 or with Python 3.7
    if [ $PYTHON != "2.7" ] || [ $U_WIDTH = "32" ]; then
      if [ $PYTHON != "3.7" ]; then
        $PIP install tensorflow==1.11.0
      fi
    fi

    echo "=== (${PYTHON}) Building Arrow C++ libraries ==="
    ARROW_BUILD_DIR=/tmp/build-PY${PYTHON}-${U_WIDTH}
    mkdir -p "${ARROW_BUILD_DIR}"
    pushd "${ARROW_BUILD_DIR}"
    PATH="${CPYTHON_PATH}/bin:$PATH" cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/arrow-dist \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DARROW_BUILD_TESTS=OFF \
        -DARROW_BUILD_SHARED=ON \
        -DARROW_BOOST_USE_SHARED=ON \
        -DARROW_GANDIVA_PC_CXX_FLAGS="-isystem;/opt/rh/devtoolset-2/root/usr/include/c++/4.8.2;-isystem;/opt/rh/devtoolset-2/root/usr/include/c++/4.8.2/x86_64-CentOS-linux/" \
        -DARROW_JEMALLOC=ON \
        -DARROW_RPATH_ORIGIN=ON \
        -DARROW_PYTHON=ON \
        -DARROW_PARQUET=ON \
        -DPythonInterp_FIND_VERSION=${PYTHON} \
        -DARROW_PLASMA=ON \
        -DARROW_TENSORFLOW=ON \
        -DARROW_ORC=ON \
        -DARROW_GANDIVA=${BUILD_ARROW_GANDIVA} \
        -DARROW_GANDIVA_JAVA=OFF \
        -DBoost_NAMESPACE=arrow_boost \
        -DBOOST_ROOT=/arrow_boost_dist \
        -GNinja /arrow/cpp
    ninja install
    popd

    # Check that we don't expose any unwanted symbols
    /io/scripts/check_arrow_visibility.sh

    echo "=== (${PYTHON}) Install the wheel build dependencies ==="
    $PIP install -r requirements-wheel.txt

    # Clear output directory
    rm -rf dist/
    echo "=== (${PYTHON}) Building wheel ==="
    # Remove build directory to ensure CMake gets a clean run
    rm -rf build/
    PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER setup.py build_ext \
        --inplace \
        --bundle-arrow-cpp \
        --bundle-boost \
        --boost-namespace=arrow_boost
    PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER setup.py bdist_wheel
    PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER setup.py sdist

    echo "=== (${PYTHON}) Tag the wheel with manylinux1 ==="
    mkdir -p repaired_wheels/
    auditwheel -v repair -L . dist/pyarrow-*.whl -w repaired_wheels/

    echo "=== (${PYTHON}) Testing manylinux1 wheel ==="
    source /venv-test-${PYTHON}-${U_WIDTH}/bin/activate
    pip install repaired_wheels/*.whl

    if [ $PYTHON != "2.7" ]; then
      PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER -c "import pyarrow.gandiva"
    fi
    PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER -c "import pyarrow.orc"
    PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER -c "import pyarrow.parquet"
    PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER -c "import pyarrow.plasma"

    echo "=== (${PYTHON}) Install modules required for testing ==="
    pip install -r requirements-test.txt

    # The TensorFlow test will be skipped here, since TensorFlow is not
    # manylinux1 compatible; however, the wheels will support TensorFlow on
    # a TensorFlow compatible system
    py.test -v -r sxX --durations=15 --parquet ${VIRTUAL_ENV}/lib/*/site-packages/pyarrow
    deactivate

    mv repaired_wheels/*.whl /io/dist
    mv dist/*.tar.gz /io/dist
done
