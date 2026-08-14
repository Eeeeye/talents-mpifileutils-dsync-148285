# Upstream source

This tree is based on the public `hpc/mpifileutils` repository at commit
`7d59002c734400b299edbe56bc672bcf158ff5d5`. The upstream project provides
MPI-based tools for copying, comparing, and synchronizing large HPC file
trees.

The candidate tree is a focused, buildable source distribution containing the
shared `libmfu` code plus the `dcmp` and `dsync` tools. The unmodified complete
upstream snapshot is retained in the authoring source archive.

The original `LICENSE`, `NOTICE`, `AUTHORS`, and copyright statements are
retained. The three build dependencies are vendored by the environment at
fixed public release commits:

- libcircle v0.3: `3d8fbfae2b95fafe71a309fcfbb7c1c993f16ad8`
- LWGRP v1.0.3: `9896d09899e2c7243e7c26622cee440436cfb42e`
- DTCMP v1.1.1: `d77b8e3af91c98669b6c3119617d022fbd5399ee`

No online dependency download is needed after the environment image has been
built.
