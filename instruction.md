# Repair mpiFileUtils incremental synchronization consistency

## Background

`mpiFileUtils` is used on HPC systems to compare and synchronize large POSIX
directory trees with multiple MPI ranks. A public operator report described an
incomplete Lustre source walk followed by `dsync --delete` removing valid
destination data. Other reports from the same release window showed that
repeated synchronizations could miss symbolic-link changes, ignore an explicit
dereference request, or recopy unchanged files when the two filesystems expose
different timestamp precision. Additional public reports showed successful
status for an unusable destination parent, copy and metadata work continuing
after a destination-path failure, a single-file sync replacing a destination
directory symlink, and sparse files expanding when FIEMAP is unavailable even
though the filesystem exposes sparse seek semantics.

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
  timestamp fields differ on a whole-second-precision filesystem;
- a missing destination parent can emit an error but return success, while a
  parent component that is a regular file can still lead into walk, copy, and
  metadata phases;
- synchronizing one file into a destination that is a symbolic link to a
  directory can replace the link itself instead of creating a child file;
- `--sparse` can materially allocate source holes on tmpfs, where sparse seek
  operations work but FIEMAP does not.

Run the supplied reproducer:

```bash
cd /workspace/mpifileutils
./scripts/build.sh
./scripts/reproduce.sh
```

A captured Starter run is available at
`/workspace/mpifileutils/logs/starter-reproduction.log`.

The supplied reproducer prints representative summaries for all seven defect
classes. The hidden verification varies ranks, path shapes, link targets,
timestamps, and sparse extent positions.

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

### 5. Destination-path validation and phase safety

Before walking the source, `dsync` must validate the ancestry needed to create
the destination:

- if the destination parent does not exist, or an ancestor component that must
  be a directory is instead a regular file, the command must return nonzero;
- the invalid path must not be created or replaced, existing parent bytes and
  type must remain unchanged, and source walk, copy, and metadata-update phases
  must not start;
- the diagnostic must identify the invalid or inaccessible destination parent.

If a destination that existed during argument processing later fails its walk,
the command must return nonzero after the walk diagnostic and must not continue
into deletion, copy, ownership, permission, timestamp, or final metadata work.
A destination that does not yet exist is not a walk failure when its valid,
writable parent allows it to be created. Existing single-file replacement and
directory creation behavior must remain available.

### 6. Existing destination-directory topology

When a single non-directory source is synchronized to an existing directory,
the source basename must be retained:

- a regular destination directory must remain a directory and receive
  `DESTINATION/BASENAME`;
- a destination symbolic link whose referent is a directory must remain the
  same symbolic link with the same stored target text, while the referent
  receives `BASENAME`;
- with `--no-dereference`, a single source symbolic link copied through either
  directory form must become a child symbolic link with identical target text.

This must not add an extra source-directory level to ordinary directory syncs,
and synchronizing one regular file directly onto another regular file must
still replace the destination bytes rather than create a child path.

### 7. Sparse-file layout

With `--sparse`, copying a regular file must preserve its logical size and all
bytes while avoiding material allocation for holes. This includes files with
leading, interior, or trailing holes and files containing no data extents.
On tmpfs, where FIEMAP may be unavailable but sparse seek semantics are
available, the destination allocation reported by `stat` must remain
materially sparse and within a small filesystem-granularity tolerance of the
source allocation.

The extent-aware path must work with MPI chunking and a repeated `--sparse`
sync must leave bytes, logical size, allocated-block count, mode, and mtime
unchanged. Ordinary fully allocated files must still copy byte-for-byte, and
invoking `dsync` without `--sparse` must retain its existing behavior.

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
small files and directories plus bounded files under the container's existing
tmpfs; no privileged mount, Lustre mount, or Slurm daemon is required.

## Modification limits

You may modify source and build files under `/workspace/mpifileutils`, including
`src/**`, `CMakeLists.txt`, and `scripts/build.sh`. Do not replace system MPI,
the fixed libraries in `/opt/mfu-deps`, or `/opt/environment-package-versions.txt`.
Do not install packages or fetch code from the network. Do not rename the
`dsync` or `dcmp` executables or change the documented CLI surface.
