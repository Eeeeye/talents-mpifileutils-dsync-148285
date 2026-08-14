#!/bin/bash
set -euo pipefail

project_root=/workspace/mpifileutils
reference_patch=/solution/reference.patch
v7_patch=/solution/reference-v7.patch

cd "${project_root}"

apply_reference_patch() {
    local patch_file=$1
    if patch --dry-run --silent -p1 < "${patch_file}"; then
        patch --batch --forward -p1 < "${patch_file}"
    elif patch --dry-run --silent --reverse -p1 < "${patch_file}"; then
        printf 'Reference repair is already applied: %s\n' "${patch_file}"
    else
        printf 'Reference patch does not match the checked-out tree: %s\n' \
            "${patch_file}" >&2
        exit 1
    fi
}

apply_reference_patch "${reference_patch}"
apply_reference_patch "${v7_patch}"

./scripts/build.sh
