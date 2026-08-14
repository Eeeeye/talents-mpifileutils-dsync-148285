#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${project_root}/build"
build_jobs="${BUILD_JOBS:-2}"

cmake -S "${project_root}" -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_COMPILER=mpicc \
    -DWITH_DTCMP_PREFIX=/opt/mfu-deps \
    -DWITH_LibCircle_PREFIX=/opt/mfu-deps \
    -DENABLE_DAOS=OFF \
    -DENABLE_EXPERIMENTAL=OFF \
    -DENABLE_GPFS=OFF \
    -DENABLE_HDF5=OFF \
    -DENABLE_LIBARCHIVE=OFF \
    -DENABLE_LUSTRE=OFF \
    -DENABLE_XATTRS=ON

cmake --build "${build_dir}" --target dsync dcmp -j "${build_jobs}"
