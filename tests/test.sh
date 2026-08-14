#!/bin/bash
set -Eeuo pipefail

log_dir=/logs/verifier
mkdir -p "${log_dir}"

if [[ "$(id -u)" -eq 0 && "${MFU_VERIFIER_AS_USER:-0}" != 1 ]]; then
    chown -R ubuntu:ubuntu "${log_dir}" /workspace/mpifileutils
    exec runuser -u ubuntu -- env \
        MFU_VERIFIER_AS_USER=1 \
        PATH="${PATH}" \
        LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
        OMPI_MCA_rmaps_base_oversubscribe=1 \
        bash /tests/test.sh
fi

exec > >(tee "${log_dir}/dsync-verifier.log") 2>&1

reward=0
case_root=""

finish() {
    status=$?
    if [[ -n "${case_root}" && -d "${case_root}" ]]; then
        chmod -R u+rwx "${case_root}" 2>/dev/null || true
        rm -rf "${case_root}"
    fi
    if [[ "${status}" -ne 0 ]]; then
        reward=0
    fi
    printf '%s\n' "${reward}" > "${log_dir}/reward.txt"
}
trap finish EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

assert_file() {
    [[ -f "$1" && ! -L "$1" ]] || fail "expected regular file: $1"
}

assert_link() {
    [[ -L "$1" ]] || fail "expected symbolic link: $1"
}

assert_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "expected path to be absent: $1"
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "$3 (expected '$1', observed '$2')"
}

project_root=/workspace/mpifileutils
cd "${project_root}"
./scripts/build.sh

dsync_bin="${project_root}/build/src/dsync/dsync"
dcmp_bin="${project_root}/build/src/dcmp/dcmp"
[[ -x "${dsync_bin}" ]] || fail "dsync was not built"
[[ -x "${dcmp_bin}" ]] || fail "dcmp was not built"

run_dsync() {
    ranks="$1"
    shift
    timeout 60s mpirun --oversubscribe -n "${ranks}" "${dsync_bin}" "$@"
}

run_dcmp() {
    ranks="$1"
    shift
    timeout 60s mpirun --oversubscribe -n "${ranks}" "${dcmp_bin}" "$@"
}

nonce="$(date +%s%N)-$$"
case_root="$(mktemp -d "/tmp/dsync-verifier-${nonce}.XXXXXX")"

printf '\n[1] ordinary MPI copy, metadata, whitespace, and successful delete\n'
basic="${case_root}/ordinary tree"
mkdir -p "${basic}/source/nested data"
printf 'alpha-%s\n' "${nonce}" > "${basic}/source/nested data/payload.bin"
chmod 0640 "${basic}/source/nested data/payload.bin"
setfattr -n user.dataset -v "batch-${nonce}" "${basic}/source/nested data/payload.bin"
ln -s 'nested data/payload.bin' "${basic}/source/current link"
run_dsync 3 -X all "${basic}/source" "${basic}/destination" >/dev/null
cmp "${basic}/source/nested data/payload.bin" "${basic}/destination/nested data/payload.bin" \
    || fail "ordinary file bytes differ"
assert_equal "640" "$(stat -c '%a' "${basic}/destination/nested data/payload.bin")" \
    "file mode was not preserved"
assert_equal "batch-${nonce}" \
    "$(getfattr --only-values -n user.dataset "${basic}/destination/nested data/payload.bin" 2>/dev/null)" \
    "extended attribute was not preserved"
assert_equal 'nested data/payload.bin' "$(readlink "${basic}/destination/current link")" \
    "symbolic link was not copied"
printf 'remove me\n' > "${basic}/destination/destination-only.dat"
run_dsync 2 --delete -X all "${basic}/source" "${basic}/destination" >/dev/null
assert_absent "${basic}/destination/destination-only.dat"
pass "ordinary copy and successful --delete"

printf '\n[2] failed source walk disables destructive deletion but keeps useful work\n'
walk="${case_root}/walk-${nonce}"
mkdir -p "${walk}/source/restricted" "${walk}/destination/restricted"
printf 'checkpoint-%s\n' "${nonce}" > "${walk}/source/restricted/checkpoint.dat"
printf 'checkpoint-%s\n' "${nonce}" > "${walk}/destination/restricted/checkpoint.dat"
printf 'hidden-retain-%s\n' "${nonce}" > "${walk}/destination/restricted/destination-state.dat"
printf 'top-retain-%s\n' "${nonce}" > "${walk}/destination/destination-only.dat"
printf 'new-visible-payload-%s\n' "${nonce}" > "${walk}/source/visible.dat"
printf 'old-%s\n' "${nonce}" > "${walk}/destination/visible.dat"
chmod 000 "${walk}/source/restricted"
set +e
run_dsync 2 --delete "${walk}/source" "${walk}/destination" \
    > "${walk}/failed-walk.log" 2>&1
walk_rc=$?
set -e
chmod 700 "${walk}/source/restricted"
chmod 700 "${walk}/destination/restricted" 2>/dev/null || true
assert_equal "0" "${walk_rc}" "partial source walk changed the established continuation status"
assert_file "${walk}/destination/restricted/checkpoint.dat"
assert_file "${walk}/destination/restricted/destination-state.dat"
assert_file "${walk}/destination/destination-only.dat"
cmp "${walk}/source/visible.dat" "${walk}/destination/visible.dat" \
    || fail "visible source work did not continue after the walk error"
grep -Eiq 'source.*walk|walk.*source' "${walk}/failed-walk.log" \
    || fail "source-walk diagnostic is missing"
grep -Eiq 'delete[^[:cntrl:]]*disabl|disabl[^[:cntrl:]]*delete' "${walk}/failed-walk.log" \
    || fail "delete-disabled diagnostic is missing"
run_dsync 2 --delete "${walk}/source" "${walk}/destination" >/dev/null
assert_absent "${walk}/destination/destination-only.dat"
assert_absent "${walk}/destination/restricted/destination-state.dat"
assert_file "${walk}/destination/restricted/checkpoint.dat"
pass "failed-walk safety and successful-walk delete distinction"

printf '\n[3] symbolic-link targets participate in dcmp and dsync\n'
links="${case_root}/links-${nonce}"
mkdir -p "${links}/source"
printf 'A-%s\n' "${nonce}" > "${links}/source/generation-A"
printf 'B-%s\n' "${nonce}" > "${links}/source/generation-A-extended"
ln -s generation-A "${links}/source/current"
ln -s missing-A "${links}/source/dangling"
ln -s "${links}/source/generation-A" "${links}/source/absolute"
run_dsync 2 "${links}/source" "${links}/destination" >/dev/null
rm "${links}/source/current" "${links}/source/dangling" "${links}/source/absolute"
ln -s generation-A-extended "${links}/source/current"
ln -s missing-A-extended "${links}/source/dangling"
ln -s "${links}/source/generation-A-extended" "${links}/source/absolute"
run_dcmp 2 -t -o "CONTENT=DIFFER:${links}/different.txt" \
    "${links}/source" "${links}/destination" >/dev/null
for link_name in current dangling absolute; do
    grep -Fq "/${link_name}" "${links}/different.txt" \
        || fail "dcmp missed changed link target: ${link_name}"
done
run_dsync 2 "${links}/source" "${links}/destination" >/dev/null
assert_equal generation-A-extended "$(readlink "${links}/destination/current")" \
    "relative link target was not synchronized"
assert_equal missing-A-extended "$(readlink "${links}/destination/dangling")" \
    "dangling link target was not synchronized"
assert_equal "${links}/source/generation-A-extended" "$(readlink "${links}/destination/absolute")" \
    "absolute link target was not synchronized"
run_dcmp 2 -t -o "CONTENT=DIFFER:${links}/after.txt" \
    "${links}/source" "${links}/destination" >/dev/null
for link_name in current dangling absolute; do
    if grep -Fq "/${link_name}" "${links}/after.txt" 2>/dev/null; then
        fail "dcmp always reports a matching link as different: ${link_name}"
    fi
done
before_link_mtime="$(stat -c '%y' "${links}/destination/current")"
run_dsync 1 "${links}/source" "${links}/destination" >/dev/null
assert_equal "${before_link_mtime}" "$(stat -c '%y' "${links}/destination/current")" \
    "matching link was rewritten on repeat sync"
pass "relative, absolute, and dangling link comparison"

printf '\n[4] dereference mode and option order\n'
deref="${case_root}/deref-${nonce}"
mkdir -p "${deref}/source"
printf 'materialized-%s\n' "${nonce}" > "${deref}/source/payload.dat"
ln -s payload.dat "${deref}/source/link.dat"
run_dsync 2 --dereference "${deref}/source" "${deref}/dest-L" >/dev/null
assert_file "${deref}/dest-L/link.dat"
cmp "${deref}/source/payload.dat" "${deref}/dest-L/link.dat" \
    || fail "dereferenced file bytes differ"
run_dsync 2 --no-dereference "${deref}/source" "${deref}/dest-P" >/dev/null
assert_link "${deref}/dest-P/link.dat"
run_dsync 2 -P -L "${deref}/source" "${deref}/dest-last-L" >/dev/null
assert_file "${deref}/dest-last-L/link.dat"
run_dsync 2 -L -P "${deref}/source" "${deref}/dest-last-P" >/dev/null
assert_link "${deref}/dest-last-P/link.dat"
pass "dereference, no-dereference, and last-option semantics"

printf '\n[5] coarse and high-resolution mtime boundaries\n'
coarse="${case_root}/coarse-${nonce}"
mkdir -p "${coarse}/source" "${coarse}/destination"
printf 'same-%s\n' "${nonce}" > "${coarse}/source/sample.dat"
printf 'same-%s\n' "${nonce}" > "${coarse}/destination/sample.dat"
touch -d '2025-01-02 03:04:05.111111111 UTC' "${coarse}/source/sample.dat"
touch -d '2025-01-02 03:04:05.999999999 UTC' "${coarse}/destination/sample.dat"
touch -d '2025-01-02 03:04:00.000000000 UTC' "${coarse}/source" "${coarse}/destination"
coarse_before="$(stat -c '%y' "${coarse}/destination/sample.dat")"
run_dsync 2 "${coarse}/source" "${coarse}/destination" >/dev/null
assert_equal "${coarse_before}" "$(stat -c '%y' "${coarse}/destination/sample.dat")" \
    "nanosecond-only mismatch caused a coarse-filesystem rewrite"

highres="${case_root}/highres-${nonce}"
mkdir -p "${highres}/source" "${highres}/destination"
printf 'same-%s\n' "${nonce}" > "${highres}/source/sample.dat"
printf 'same-%s\n' "${nonce}" > "${highres}/destination/sample.dat"
touch -d '2025-02-03 04:05:06.111111111 UTC' "${highres}/source/sample.dat"
touch -d '2025-02-03 04:05:06.999999999 UTC' "${highres}/destination/sample.dat"
touch -d '2025-02-03 04:05:00.111111111 UTC' "${highres}/source"
touch -d '2025-02-03 04:05:00.222222222 UTC' "${highres}/destination"
expected_highres="$(stat -c '%y' "${highres}/source/sample.dat")"
run_dsync 2 "${highres}/source" "${highres}/destination" >/dev/null
assert_equal "${expected_highres}" "$(stat -c '%y' "${highres}/destination/sample.dat")" \
    "real nanosecond difference was ignored on high-resolution paths"
pass "timestamp precision boundaries"

printf '\n[6] missing destination, --contents, dry-run, and repeat idempotence\n'
content_case="${case_root}/content-${nonce}"
mkdir -p "${content_case}/source" "${content_case}/destination"
printf 'AAAA-%s\n' "${nonce}" > "${content_case}/source/equal-size.dat"
printf 'BBBB-%s\n' "${nonce}" > "${content_case}/destination/equal-size.dat"
touch -d '2025-03-04 05:06:07.123456789 UTC' \
    "${content_case}/source/equal-size.dat" "${content_case}/destination/equal-size.dat"
run_dsync 2 --contents "${content_case}/source" "${content_case}/destination" >/dev/null
cmp "${content_case}/source/equal-size.dat" "${content_case}/destination/equal-size.dat" \
    || fail "--contents failed to replace equal-size equal-mtime bytes"

missing="${case_root}/missing-${nonce}"
mkdir -p "${missing}/source"
printf 'first-copy-%s\n' "${nonce}" > "${missing}/source/new.dat"
run_dsync 2 "${missing}/source" "${missing}/destination" >/dev/null
cmp "${missing}/source/new.dat" "${missing}/destination/new.dat" \
    || fail "first copy to missing destination failed"

dry="${case_root}/dry-${nonce}"
mkdir -p "${dry}/source" "${dry}/destination"
printf 'new-%s\n' "${nonce}" > "${dry}/source/item.dat"
printf 'old-%s\n' "${nonce}" > "${dry}/destination/item.dat"
dry_before="$(sha256sum "${dry}/destination/item.dat")"
run_dsync 2 --dryrun --contents "${dry}/source" "${dry}/destination" >/dev/null
assert_equal "${dry_before}" "$(sha256sum "${dry}/destination/item.dat")" \
    "--dryrun mutated destination bytes"

idem_file="${basic}/destination/nested data/payload.bin"
idem_before="$(sha256sum "${idem_file}")|$(stat -c '%a|%y' "${idem_file}")|$(getfattr --only-values -n user.dataset "${idem_file}" 2>/dev/null)|$(readlink "${basic}/destination/current link")"
run_dsync 2 -X all "${basic}/source" "${basic}/destination" >/dev/null
idem_after="$(sha256sum "${idem_file}")|$(stat -c '%a|%y' "${idem_file}")|$(getfattr --only-values -n user.dataset "${idem_file}" 2>/dev/null)|$(readlink "${basic}/destination/current link")"
assert_equal "${idem_before}" "${idem_after}" "repeat synchronization changed preserved state"
pass "content mode, dry-run, missing destination, and idempotence"

reward=1
printf '\nALL TESTS PASSED\n'
