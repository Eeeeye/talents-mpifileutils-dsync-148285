#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dsync_bin="${project_root}/build/src/dsync/dsync"
dcmp_bin="${project_root}/build/src/dcmp/dcmp"
case_root="$(mktemp -d /tmp/dsync-reproduction.XXXXXX)"

cleanup() {
    chmod -R u+rwx "${case_root}" 2>/dev/null || true
    rm -rf "${case_root}"
}
trap cleanup EXIT

run_dsync() {
    mpirun --oversubscribe -n 2 "${dsync_bin}" "$@"
}

run_dcmp() {
    mpirun --oversubscribe -n 2 "${dcmp_bin}" "$@"
}

printf 'case 1: incomplete source walk with --delete\n'
mkdir -p "${case_root}/walk/src/restricted" "${case_root}/walk/dst/restricted"
printf 'retain\n' > "${case_root}/walk/src/restricted/checkpoint.dat"
printf 'retain\n' > "${case_root}/walk/dst/restricted/checkpoint.dat"
printf 'new-visible-payload\n' > "${case_root}/walk/src/visible.dat"
printf 'old\n' > "${case_root}/walk/dst/visible.dat"
chmod 000 "${case_root}/walk/src/restricted"
run_dsync --delete "${case_root}/walk/src" "${case_root}/walk/dst" \
    > "${case_root}/walk/output.log" 2>&1
chmod 700 "${case_root}/walk/src/restricted"
chmod 700 "${case_root}/walk/dst/restricted" 2>/dev/null || true
if [[ -f "${case_root}/walk/dst/restricted/checkpoint.dat" ]]; then
    printf 'destination checkpoint: retained\n'
else
    printf 'destination checkpoint: missing\n'
fi
grep -E 'ERROR|delete option' "${case_root}/walk/output.log" || true

printf '\ncase 2: changed symbolic-link target\n'
mkdir -p "${case_root}/links/src"
printf 'A\n' > "${case_root}/links/src/generation-A"
printf 'B\n' > "${case_root}/links/src/generation-B"
ln -s generation-A "${case_root}/links/src/current"
run_dsync "${case_root}/links/src" "${case_root}/links/dst" >/dev/null
rm "${case_root}/links/src/current"
ln -s generation-B "${case_root}/links/src/current"
run_dcmp -t -o "CONTENT=DIFFER:${case_root}/links/different.txt" \
    "${case_root}/links/src" "${case_root}/links/dst" >/dev/null
if grep -Fq '/current' "${case_root}/links/different.txt" 2>/dev/null; then
    printf 'dcmp classification: different\n'
else
    printf 'dcmp classification: common\n'
fi
run_dsync "${case_root}/links/src" "${case_root}/links/dst" >/dev/null
printf 'destination target: %s\n' "$(readlink "${case_root}/links/dst/current")"

printf '\ncase 3: --dereference\n'
mkdir -p "${case_root}/dereference/src"
printf 'materialized payload\n' > "${case_root}/dereference/src/payload.dat"
ln -s payload.dat "${case_root}/dereference/src/link.dat"
run_dsync --dereference "${case_root}/dereference/src" "${case_root}/dereference/dst" >/dev/null
if [[ -L "${case_root}/dereference/dst/link.dat" ]]; then
    printf 'destination type: symbolic link\n'
else
    printf 'destination type: regular file\n'
fi

printf '\ncase 4: whole-second timestamp precision\n'
mkdir -p "${case_root}/mtime/src" "${case_root}/mtime/dst"
printf 'same bytes\n' > "${case_root}/mtime/src/sample.dat"
printf 'same bytes\n' > "${case_root}/mtime/dst/sample.dat"
touch -d '2025-01-02 03:04:05.111111111 UTC' "${case_root}/mtime/src/sample.dat"
touch -d '2025-01-02 03:04:05.999999999 UTC' "${case_root}/mtime/dst/sample.dat"
touch -d '2025-01-02 03:04:00.000000000 UTC' "${case_root}/mtime/src" "${case_root}/mtime/dst"
before_mtime="$(stat -c '%y' "${case_root}/mtime/dst/sample.dat")"
run_dsync "${case_root}/mtime/src" "${case_root}/mtime/dst" >/dev/null
after_mtime="$(stat -c '%y' "${case_root}/mtime/dst/sample.dat")"
printf 'destination mtime before: %s\n' "${before_mtime}"
printf 'destination mtime after:  %s\n' "${after_mtime}"
