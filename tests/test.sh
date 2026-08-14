#!/bin/bash
set -Eeuo pipefail

log_dir=/logs/verifier
mkdir -p "${log_dir}"

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

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
shm_root=""

finish() {
    status=$?
    if [[ -n "${case_root}" && -d "${case_root}" ]]; then
        chmod -R u+rwx "${case_root}" 2>/dev/null || true
        rm -rf "${case_root}"
    fi
    if [[ -n "${shm_root}" && -d "${shm_root}" ]]; then
        chmod -R u+rwx "${shm_root}" 2>/dev/null || true
        rm -rf "${shm_root}"
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

assert_no_phase() {
    log_file=$1
    phase_pattern=$2
    description=$3
    if grep -Eq "${phase_pattern}" "${log_file}"; then
        fail "${description}"
    fi
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
xattr_helper="${case_root}/xattr-helper"
cc -std=c11 -O2 -Wall -Wextra -Werror \
    "${test_dir}/xattr_helper.c" -o "${xattr_helper}"

printf '\n[1] ordinary MPI copy, metadata, whitespace, and successful delete\n'
basic="${case_root}/ordinary tree"
mkdir -p "${basic}/source/nested data"
printf 'alpha-%s\n' "${nonce}" > "${basic}/source/nested data/payload.bin"
chmod 0640 "${basic}/source/nested data/payload.bin"
chmod 0750 "${basic}/source/nested data"
"${xattr_helper}" set "${basic}/source/nested data/payload.bin" user.dataset "batch-${nonce}"
ln -s 'nested data/payload.bin' "${basic}/source/current link"
run_dsync 3 -X all "${basic}/source" "${basic}/destination" >/dev/null
cmp "${basic}/source/nested data/payload.bin" "${basic}/destination/nested data/payload.bin" \
    || fail "ordinary file bytes differ"
assert_equal "640" "$(stat -c '%a' "${basic}/destination/nested data/payload.bin")" \
    "file mode was not preserved"
assert_equal "750" "$(stat -c '%a' "${basic}/destination/nested data")" \
    "directory mode was not preserved"
assert_equal "batch-${nonce}" \
    "$("${xattr_helper}" get "${basic}/destination/nested data/payload.bin" user.dataset)" \
    "extended attribute was not preserved"
assert_equal 'nested data/payload.bin' "$(readlink "${basic}/destination/current link")" \
    "symbolic link was not copied"
printf 'remove me\n' > "${basic}/destination/destination-only.dat"
run_dsync 2 --delete -X all "${basic}/source" "${basic}/destination" >/dev/null
assert_absent "${basic}/destination/destination-only.dat"
pass "ordinary copy and successful --delete"

printf '\n[2] failed source walk disables destructive deletion but keeps useful work\n'
walk="${case_root}/walk-${nonce}"
mkdir -p \
    "${walk}/source/restricted" \
    "${walk}/destination/restricted" \
    "${walk}/source/discovered-dir" \
    "${walk}/destination/discovered-dir"
printf 'checkpoint-%s\n' "${nonce}" > "${walk}/source/restricted/checkpoint.dat"
printf 'checkpoint-%s\n' "${nonce}" > "${walk}/destination/restricted/checkpoint.dat"
printf 'hidden-retain-%s\n' "${nonce}" > "${walk}/destination/restricted/destination-state.dat"
printf 'top-retain-%s\n' "${nonce}" > "${walk}/destination/destination-only.dat"
printf 'new-visible-payload-%s\n' "${nonce}" > "${walk}/source/visible.dat"
printf 'old-%s\n' "${nonce}" > "${walk}/destination/visible.dat"
printf 'metadata-only-%s\n' "${nonce}" > "${walk}/source/metadata-only.dat"
cp "${walk}/source/metadata-only.dat" "${walk}/destination/metadata-only.dat"
touch -d '2025-04-05 06:07:08.123456789 UTC' \
    "${walk}/source/metadata-only.dat" "${walk}/destination/metadata-only.dat"
chmod 0640 "${walk}/source/metadata-only.dat"
chmod 0600 "${walk}/destination/metadata-only.dat"
chmod 0750 "${walk}/source/discovered-dir"
chmod 0700 "${walk}/destination/discovered-dir"
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
assert_equal "640" "$(stat -c '%a' "${walk}/destination/metadata-only.dat")" \
    "metadata-only update did not continue after the walk error"
assert_equal "750" "$(stat -c '%a' "${walk}/destination/discovered-dir")" \
    "discovered directory permissions were not synchronized after the walk error"
grep -Eiq 'source.*walk|walk.*source' "${walk}/failed-walk.log" \
    || fail "source-walk diagnostic is missing"
grep -Eiq 'delete[^[:cntrl:]]*disabl|disabl[^[:cntrl:]]*delete' "${walk}/failed-walk.log" \
    || fail "delete-disabled diagnostic is missing"
run_dsync 2 --delete "${walk}/source" "${walk}/destination" >/dev/null
assert_absent "${walk}/destination/destination-only.dat"
assert_absent "${walk}/destination/restricted/destination-state.dat"
assert_file "${walk}/destination/restricted/checkpoint.dat"
pass "failed-walk safety and successful-walk delete distinction"

printf '\n[3] zero-item invalid-source guard protects the destination\n'
invalid="${case_root}/invalid-${nonce}"
mkdir -p "${invalid}/destination/retained-dir"
printf 'retain-%s\n' "${nonce}" > "${invalid}/destination/retained-dir/state.dat"
invalid_before="$(sha256sum "${invalid}/destination/retained-dir/state.dat")|$(stat -c '%a' "${invalid}/destination/retained-dir")"
set +e
run_dsync 2 --delete "${invalid}/source-does-not-exist" "${invalid}/destination" \
    > "${invalid}/invalid-source.log" 2>&1
invalid_rc=$?
set -e
[[ "${invalid_rc}" -ne 0 ]] || fail "invalid zero-item source unexpectedly succeeded"
assert_file "${invalid}/destination/retained-dir/state.dat"
invalid_after="$(sha256sum "${invalid}/destination/retained-dir/state.dat")|$(stat -c '%a' "${invalid}/destination/retained-dir")"
assert_equal "${invalid_before}" "${invalid_after}" \
    "invalid zero-item source changed protected destination state"
grep -Eiq 'no items found at source|invalid source|source.*not found' \
    "${invalid}/invalid-source.log" \
    || fail "invalid-source guard diagnostic is missing"
pass "invalid source guard and destination preservation"

printf '\n[4] symbolic-link targets participate in dcmp and dsync\n'
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

printf '\n[5] dereference mode and option order\n'
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

printf '\n[6] coarse and high-resolution mtime boundaries\n'
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

printf '\n[7] missing destination, --contents, dry-run, and repeat idempotence\n'
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
idem_before="$(sha256sum "${idem_file}")|$(stat -c '%a|%y' "${idem_file}")|$("${xattr_helper}" get "${idem_file}" user.dataset)|$(readlink "${basic}/destination/current link")|$(stat -c '%a' "${basic}/destination/nested data")"
run_dsync 2 -X all "${basic}/source" "${basic}/destination" >/dev/null
idem_after="$(sha256sum "${idem_file}")|$(stat -c '%a|%y' "${idem_file}")|$("${xattr_helper}" get "${idem_file}" user.dataset)|$(readlink "${basic}/destination/current link")|$(stat -c '%a' "${basic}/destination/nested data")"
assert_equal "${idem_before}" "${idem_after}" "repeat synchronization changed preserved state"
pass "content mode, dry-run, missing destination, and idempotence"

printf '\n[8] invalid destination ancestry and failed walks abort later phases\n'
dest_guard="${case_root}/destination-guard-${nonce}"
mkdir -p "${dest_guard}/source"
printf 'guard-source-%s\n' "${nonce}" > "${dest_guard}/source/item.dat"

set +e
run_dsync 2 "${dest_guard}/source/item.dat" \
    "${dest_guard}/missing-parent/output.dat" \
    > "${dest_guard}/missing-parent.log" 2>&1
missing_parent_rc=$?
set -e
[[ "${missing_parent_rc}" -ne 0 ]] \
    || fail "missing destination parent returned success"
assert_absent "${dest_guard}/missing-parent"
grep -Eiq 'destination.*parent|parent.*destination' \
    "${dest_guard}/missing-parent.log" \
    || fail "missing-parent diagnostic is absent"
assert_no_phase "${dest_guard}/missing-parent.log" \
    'Walking source path|Copying items to destination|Setting ownership, permissions, and timestamps|Updating timestamps on newly copied files' \
    "missing parent reached source, copy, or metadata work"

printf 'parent-sentinel-%s\n' "${nonce}" > "${dest_guard}/not-a-directory"
parent_before="$(sha256sum "${dest_guard}/not-a-directory")|$(stat -c '%F|%a' "${dest_guard}/not-a-directory")"
set +e
run_dsync 3 "${dest_guard}/source/item.dat" \
    "${dest_guard}/not-a-directory/output.dat" \
    > "${dest_guard}/parent-file.log" 2>&1
parent_file_rc=$?
set -e
[[ "${parent_file_rc}" -ne 0 ]] \
    || fail "non-directory destination parent returned success"
parent_after="$(sha256sum "${dest_guard}/not-a-directory")|$(stat -c '%F|%a' "${dest_guard}/not-a-directory")"
assert_equal "${parent_before}" "${parent_after}" \
    "non-directory parent state changed"
grep -Eiq 'not a directory|destination.*parent|parent.*destination' \
    "${dest_guard}/parent-file.log" \
    || fail "non-directory-parent diagnostic is absent"
assert_no_phase "${dest_guard}/parent-file.log" \
    'Walking source path|Copying items to destination|Setting ownership, permissions, and timestamps|Updating timestamps on newly copied files' \
    "non-directory parent reached source, copy, or metadata work"

mkdir -p "${dest_guard}/walk-source" "${dest_guard}/walk-destination"
printf 'walk-source-%s\n' "${nonce}" > "${dest_guard}/walk-source/item.dat"
printf 'walk-destination-%s\n' "${nonce}" > "${dest_guard}/walk-destination/state.dat"
walk_dest_before="$(sha256sum "${dest_guard}/walk-destination/state.dat")"
chmod 000 "${dest_guard}/walk-destination"
set +e
run_dsync 2 "${dest_guard}/walk-source" "${dest_guard}/walk-destination" \
    > "${dest_guard}/destination-walk.log" 2>&1
destination_walk_rc=$?
set -e
chmod 0700 "${dest_guard}/walk-destination"
[[ "${destination_walk_rc}" -ne 0 ]] \
    || fail "failed destination walk returned success"
assert_equal "${walk_dest_before}" \
    "$(sha256sum "${dest_guard}/walk-destination/state.dat")" \
    "failed destination walk changed destination bytes"
grep -Eiq 'destination.*walk|walk.*destination' \
    "${dest_guard}/destination-walk.log" \
    || fail "destination-walk diagnostic is absent"
assert_no_phase "${dest_guard}/destination-walk.log" \
    'Deleting items from destination|Copying items to destination|Setting ownership, permissions, and timestamps|Updating timestamps on newly copied files' \
    "failed destination walk continued into destructive or metadata work"
pass "destination ancestry and failed-walk phase safety"

printf '\n[9] single-file topology for real and symlinked directories\n'
topology="${case_root}/topology-${nonce}"
mkdir -p "${topology}/source" "${topology}/real-destination" \
    "${topology}/link-referent"
printf 'topology-payload-%s\n' "${nonce}" > "${topology}/source/payload.dat"
run_dsync 1 "${topology}/source/payload.dat" \
    "${topology}/real-destination" >/dev/null
[[ -d "${topology}/real-destination" && ! -L "${topology}/real-destination" ]] \
    || fail "real destination directory was replaced"
cmp "${topology}/source/payload.dat" \
    "${topology}/real-destination/payload.dat" \
    || fail "single-file basename was not retained in a real directory"

ln -s link-referent "${topology}/destination-link"
destination_link_before="$(readlink "${topology}/destination-link")"
run_dsync 2 "${topology}/source/payload.dat" \
    "${topology}/destination-link" >/dev/null
assert_link "${topology}/destination-link"
assert_equal "${destination_link_before}" \
    "$(readlink "${topology}/destination-link")" \
    "destination directory-link target changed"
cmp "${topology}/source/payload.dat" \
    "${topology}/link-referent/payload.dat" \
    || fail "single file was not copied through a destination directory link"

ln -s payload.dat "${topology}/source/current"
run_dsync 3 --no-dereference "${topology}/source/current" \
    "${topology}/destination-link" >/dev/null
assert_link "${topology}/destination-link"
assert_link "${topology}/link-referent/current"
assert_equal 'payload.dat' "$(readlink "${topology}/link-referent/current")" \
    "single source-link target text was not retained as a child"

printf 'replacement-old-%s\n' "${nonce}" > "${topology}/replacement.dat"
run_dsync 2 "${topology}/source/payload.dat" \
    "${topology}/replacement.dat" >/dev/null
assert_file "${topology}/replacement.dat"
cmp "${topology}/source/payload.dat" "${topology}/replacement.dat" \
    || fail "direct file-to-file replacement stopped working"
pass "single-file basename, directory-link, and file replacement topology"

printf '\n[10] tmpfs sparse extent preservation and repeat stability\n'
shm_root="/dev/shm/dsync-verifier-${nonce}-$$"
mkdir -p "${shm_root}/source" "${shm_root}/destination"

sparse_src="${shm_root}/source/sparse.bin"
leading_src="${shm_root}/source/leading.bin"
empty_src="${shm_root}/source/empty-extents.bin"
ordinary_src="${shm_root}/source/ordinary.bin"

truncate -s 16777216 "${sparse_src}"
printf 'HEAD-%s' "${nonce}" | \
    dd of="${sparse_src}" bs=1 seek=0 conv=notrunc status=none
printf 'MIDDLE-%s' "${nonce}" | \
    dd of="${sparse_src}" bs=1 seek=5243003 conv=notrunc status=none

truncate -s 33554432 "${leading_src}"
printf 'LEADING-HOLE-%s' "${nonce}" | \
    dd of="${leading_src}" bs=1 seek=4194427 conv=notrunc status=none
printf 'END-%s' "${nonce}" | \
    dd of="${leading_src}" bs=1 seek=33554380 conv=notrunc status=none

truncate -s 8388608 "${empty_src}"
dd if=/dev/urandom of="${ordinary_src}" bs=131072 count=1 status=none
chmod 0640 "${sparse_src}" "${leading_src}" "${empty_src}" "${ordinary_src}"
touch -d '2026-07-08 09:10:11.123456789 UTC' \
    "${sparse_src}" "${leading_src}" "${empty_src}" "${ordinary_src}"

# Begin with a dense same-size destination to verify that old allocations are
# discarded before source holes are reconstructed.
dd if=/dev/zero of="${shm_root}/destination/sparse.bin" \
    bs=1048576 count=16 status=none

run_dsync 3 --sparse "${shm_root}/source" "${shm_root}/destination" >/dev/null

for sparse_name in sparse.bin leading.bin empty-extents.bin ordinary.bin; do
    cmp "${shm_root}/source/${sparse_name}" \
        "${shm_root}/destination/${sparse_name}" \
        || fail "sparse-mode bytes differ for ${sparse_name}"
    assert_equal "$(stat -c '%s' "${shm_root}/source/${sparse_name}")" \
        "$(stat -c '%s' "${shm_root}/destination/${sparse_name}")" \
        "logical size differs for ${sparse_name}"
done

for sparse_name in sparse.bin leading.bin empty-extents.bin; do
    sparse_size="$(stat -c '%s' "${shm_root}/source/${sparse_name}")"
    source_blocks="$(stat -c '%b' "${shm_root}/source/${sparse_name}")"
    destination_blocks="$(stat -c '%b' "${shm_root}/destination/${sparse_name}")"
    logical_blocks=$(( (sparse_size + 511) / 512 ))
    [[ "${destination_blocks}" -lt $(( logical_blocks / 2 )) ]] \
        || fail "${sparse_name} is not materially sparse (${destination_blocks}/${logical_blocks})"
    [[ "${destination_blocks}" -le $(( source_blocks + 2048 )) ]] \
        || fail "${sparse_name} allocation exceeds source tolerance (${destination_blocks}/${source_blocks})"
done

sparse_state_before=""
for sparse_name in sparse.bin leading.bin empty-extents.bin ordinary.bin; do
    sparse_state_before+="$(sha256sum "${shm_root}/destination/${sparse_name}")|"
    sparse_state_before+="$(stat -c '%s|%b|%a|%y' "${shm_root}/destination/${sparse_name}")|"
done
run_dsync 2 --sparse "${shm_root}/source" "${shm_root}/destination" >/dev/null
sparse_state_after=""
for sparse_name in sparse.bin leading.bin empty-extents.bin ordinary.bin; do
    sparse_state_after+="$(sha256sum "${shm_root}/destination/${sparse_name}")|"
    sparse_state_after+="$(stat -c '%s|%b|%a|%y' "${shm_root}/destination/${sparse_name}")|"
done
assert_equal "${sparse_state_before}" "${sparse_state_after}" \
    "repeat sparse synchronization changed bytes, allocation, mode, or mtime"
pass "leading, interior, trailing, and empty sparse extents"

reward=1
printf '\nALL TESTS PASSED\n'
