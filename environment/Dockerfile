FROM ubuntu@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG UBUNTU_SNAPSHOT=20260623T000000Z
ENV DEBIAN_FRONTEND=noninteractive

# The pinned base is intentionally minimal and does not contain a CA bundle.
# Bootstrap only the public CA bundle, then replace it with the signed package
# from the fixed Ubuntu snapshot during the normal apt transaction.
COPY bootstrap/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN sed -i \
      -e "s|http://archive.ubuntu.com/ubuntu/|https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/|" \
      -e "s|http://security.ubuntu.com/ubuntu/|https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/|" \
      /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       attr \
       autoconf \
       automake \
       build-essential \
       ca-certificates \
       cmake \
       libattr1-dev \
       libbz2-dev \
       libtool \
       openmpi-bin \
       libopenmpi-dev \
       patch \
       pkg-config \
    && dpkg-query -W -f='${Package}\t${Version}\n' | sort > /opt/environment-package-versions.txt \
    && rm -rf /var/lib/apt/lists/*

# The pinned Ubuntu image may already provide this account, but task.toml's
# Agent user must also be explicitly declared in the Dockerfile for the
# platform initializer.  Keep the step idempotent across base-image revisions.
RUN if ! id -u ubuntu >/dev/null 2>&1; then \
      useradd --create-home --shell /bin/bash ubuntu; \
    fi \
    && install -d -o ubuntu -g ubuntu /home/ubuntu

ENV MFU_DEPS_PREFIX=/opt/mfu-deps
ENV PKG_CONFIG_PATH=/opt/mfu-deps/lib/pkgconfig
ENV LD_LIBRARY_PATH=/opt/mfu-deps/lib

COPY vendor/libcircle /build/libcircle
RUN cd /build/libcircle \
    && ./autogen.sh \
    && CC=mpicc ./configure --prefix=/opt/mfu-deps \
    && make -j2 \
    && make install

COPY vendor/lwgrp /build/lwgrp
RUN cd /build/lwgrp \
    && ./autogen.sh \
    && CC=mpicc ./configure --prefix=/opt/mfu-deps \
    && make -j2 \
    && make install

COPY vendor/dtcmp /build/dtcmp
RUN cd /build/dtcmp \
    && ./autogen.sh \
    && CC=mpicc ./configure --prefix=/opt/mfu-deps --with-lwgrp=/opt/mfu-deps \
    && make -j2 \
    && make install \
    && rm -rf /build/libcircle /build/lwgrp /build/dtcmp

COPY --chown=ubuntu:ubuntu task /workspace/mpifileutils

ENV PATH=/workspace/mpifileutils/build/src/dsync:/workspace/mpifileutils/build/src/dcmp:${PATH}
ENV OMPI_MCA_rmaps_base_oversubscribe=1
WORKDIR /workspace/mpifileutils
USER ubuntu

RUN ./scripts/build.sh

# Harbor initializes Oracle and Verifier from the image's default user, which
# must be root.  The candidate Agent still runs as ubuntu via task.toml so the
# permission-sensitive source-walk failure remains observable.
USER root
