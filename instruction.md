# Repair mpiFileUtils incremental synchronization consistency

## Background

`mpiFileUtils` is used on HPC systems to compare and synchronize large POSIX
directory trees with multiple MPI ranks. A public operator report described an
incomplete Lustre source walk followed by `dsync --delete` removing valid
destination data. Other reports from the same release window showed that
repeated synchronizations could miss symbolic-link changes, ignore an explicit
dereference request, or recopy unchanged files when the two filesystems expose
different timestamp precision.

The container contains a fixed public upstream snapshot and all build
dependencies. It has no external service and the repair must not depend on
network access.

## Initial state

The project is at `/workspace/mpifileutils`. It builds successfully, but:

- an unreadable source subdirectory can make `--delete` remove entries that
  still exist in the real source tree;
- `dcmp` may classify two links with different targets as common, after which
  `dsync` leaves the stale destination link unchanged;
- `dsync --dereference` can still copy a source link as a link;
- a lite comparison can recopy equal files solely because their nanosecond
  timestamp fields differ on a whole-second-precision filesystem.

Run the supplied reproducer:

```bash
cd /workspace/mpifileutils
./scripts/build.sh
./scripts/reproduce.sh
```

A captured Starter run is available at
`/workspace/mpifileutils/logs/starter-reproduction.log`.

In the Starter, the four summaries include a missing destination checkpoint,
`dcmp classification: common`, a stale `generation-A` link, a symbolic-link
result for `--dereference`, and a rewritten destination timestamp.

## Required final behavior

### 1. Incomplete source-walk safety

When any MPI rank encounters an error while walking the source tree:

- `dsync --delete SOURCE DESTINATION` must suppress deletion of entries that
  appear destination-only in that incomplete comparison;
- entries already discovered in the source must still be eligible for normal
  copy and metadata updates;
- the command must emit a clear diagnostic stating that the source walk was
  incomplete and destination deletion was disabled;
- this recoverable partial-walk case must retain the established zero exit
  status after the useful non-delete work completes;
- the existing guard for a completely empty or invalid source must remain in
  effect.

When the source walk succeeds, `--delete` must continue to remove genuinely
destination-only entries. Disabling deletion unconditionally is not a valid
repair.

### 2. Symbolic-link comparison and synchronization

With the default no-dereference behavior (or explicit `--no-dereference`):

- a symbolic link's stored target text is part of its content;
- `dcmp` must report `CONTENT=DIFFER` when corresponding source and destination
  links have different targets;
- `dsync` must replace the destination link so its target exactly matches the
  source, including relative, absolute, and dangling targets;
- once targets match, another `dcmp` must classify them as common and another
  `dsync` must make no link change.

Existing handling of regular files, directories, and permissions must remain
intact. With `-X all`, user extended attributes must still be copied and
preserved across a repeated synchronization.

### 3. Dereference option

For a source symbolic link to a regular file:

- `--dereference` (`-L`) must materialize the referent as a regular destination
  file with the referent's bytes;
- `--no-dereference` (`-P`) must preserve the source object as a symbolic link;
- if both options are supplied, the later option on the command line controls
  the selected mode.

### 4. Timestamp precision and idempotence

The default lite comparison still uses file size and modification time.
Timestamp handling must obey these boundaries:

- if either top-level source or destination path reports a whole-second mtime
  (`tv_nsec == 0`), equal-size files whose mtime seconds match must not be
  recopied solely because their nanosecond fields differ;
- if both top-level paths expose nonzero nanoseconds, a real nanosecond mtime
  difference must still be detected and synchronized;
- inability to stat a not-yet-created destination must not be interpreted as
  proof that the filesystem lacks nanosecond precision;
- after a successful synchronization, repeating the same command must leave
  file bytes, link targets, mtimes, permissions, and xattrs unchanged.

The existing `--contents` mode must continue to detect and replace different
regular-file bytes even when size and mtime are equal. `--dryrun` must remain
non-mutating.

## Build and runtime contract

Use the existing build entry point:

```bash
cd /workspace/mpifileutils
./scripts/build.sh
```

The required executables remain:

```text
/workspace/mpifileutils/build/src/dsync/dsync
/workspace/mpifileutils/build/src/dcmp/dcmp
```

They will be exercised through Open MPI with one to three ranks, for example:

```bash
mpirun --oversubscribe -n 2 build/src/dsync/dsync SOURCE DESTINATION
```

Inputs are ordinary local POSIX paths and may contain whitespace. Tests use
small files and directories; no Lustre mount or Slurm daemon is required.

## Modification limits

You may modify source and build files under `/workspace/mpifileutils`, including
`src/**`, `CMakeLists.txt`, and `scripts/build.sh`. Do not replace system MPI,
the fixed libraries in `/opt/mfu-deps`, or `/opt/environment-package-versions.txt`.
Do not install packages or fetch code from the network. Do not rename the
`dsync` or `dcmp` executables or change the documented CLI surface.
