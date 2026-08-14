#!/bin/bash
set -euo pipefail

project_root=/workspace/mpifileutils
reference_patch=/solution/reference.patch

cd "${project_root}"

if patch --dry-run --silent -p1 < "${reference_patch}"; then
    patch --batch --forward -p1 < "${reference_patch}"
elif patch --dry-run --silent --reverse -p1 < "${reference_patch}"; then
    printf 'Reference repair is already applied.\n'
else
    printf 'Reference patch does not match the checked-out Starter.\n' >&2
    exit 1
fi

./scripts/build.sh
