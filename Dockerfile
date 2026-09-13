# Builds peregrine for one specific CPython -- the base image's -- and ships it
# alone.
#
# The server is peregrine._native, an extension module compiled against one
# CPython ABI, so it has to be built for the interpreter it will run in. The
# way to get that right is to build it *inside* the runtime image: the python
# it compiles against is then, by construction, the one that will import it.
#
#   docker build -t peregrine:3.14 .
#   docker build -t peregrine:3.13 --build-arg PYTHON_IMAGE=python:3.13-slim .
#
# The base image decides everything: which CPython the server runs in, and
# whether --free-threaded is available at all. The official python images have
# no free-threaded variant, so a base that provides one has to be built or
# brought (see INSTALLATION.md); against an ordinary one --free-threaded is
# refused.
#
# The result is a scratch-thin image for an application image to take from, in
# whichever of two ways suits it:
#
#   # installed into the image's own python, with the `peregrine` command
#   COPY --from=peregrine:3.14 /usr/local/ /usr/local/
#
#   # or the wheel, for a virtualenv
#   COPY --from=peregrine:3.14 /wheels/ /tmp/wheels/
#   RUN pip install /tmp/wheels/*.whl
#
# Either needs the same base image the server was built on. Building it once
# and copying it in keeps a Swift toolchain -- and several minutes of
# compilation -- out of every application's deploy.

ARG PYTHON_IMAGE=python:3.14-slim

# --- build ------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS build

ARG SWIFT_VERSION=6.1.2
# Swift.org publishes Ubuntu builds; they run on Debian of equal or newer
# glibc, which is what the python images are based on. SWIFT_SLUG is the same
# platform with the dot removed, which is how the download URL spells it -- as
# a separate argument because Docker runs RUN under `sh`, which has no
# substring replacement.
ARG SWIFT_PLATFORM=ubuntu24.04
ARG SWIFT_SLUG=ubuntu2404
ARG SWIFT_DIR=swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}

# Deliberately NOT libpython3-dev: that is Debian's own Python, which is a
# different minor version from the one the image ships in /usr/local, and it
# would put a second python3.pc on the pkg-config path. The base image already
# provides the headers and the .pc file for the interpreter that matters.
#
# gcc is here for its runtime objects, not its compiler: Swift drives clang,
# and clang links against crtbeginS.o and libgcc from the system GCC install.
RUN apt-get update && apt-get install -y --no-install-recommends \
        binutils curl ca-certificates gcc git libc6-dev libcurl4 libedit2 \
        libncurses6 libsqlite3-0 libssl-dev libxml2 libz3-4 \
        patchelf pkg-config tzdata unzip zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_SLUG}/swift-${SWIFT_VERSION}-RELEASE/${SWIFT_DIR}.tar.gz" \
      -o /tmp/swift.tar.gz \
    && tar -xzf /tmp/swift.tar.gz -C /tmp \
    && cp -r /tmp/${SWIFT_DIR}/usr /opt/swift \
    && rm -rf /tmp/swift.tar.gz /tmp/${SWIFT_DIR}
ENV PATH=/opt/swift/bin:$PATH

WORKDIR /src
COPY Package.swift setup.py pyproject.toml README.md ./
COPY Sources ./Sources
COPY python ./python

# Point pkg-config at the image's own interpreter explicitly, and prove it
# resolved to that one before spending five minutes compiling against it.
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
RUN python3 --version && pkg-config --modversion python3

# setup.py builds the extension, vendors the Swift runtime beside it -- the
# runtime image has no toolchain -- and imports the result in a clean
# interpreter before it will package it; on a free-threaded base it also checks
# that the import leaves the GIL off. PEREGRINE_REQUIRE_RELOCATE makes a
# missing patchelf an error rather than a wheel that only runs here.
ENV PEREGRINE_SCRATCH_PATH=/tmp/build \
    PEREGRINE_REQUIRE_RELOCATE=1
RUN python3 -m pip wheel --no-deps --wheel-dir /out/wheels . \
    && python3 -m pip install --no-deps --no-compile --prefix /out/usr/local /out/wheels/*.whl

# Prove the installed copy runs with nothing but the base image around it, from
# outside the source tree, rather than leaving it to fail in the application's
# image.
RUN cd / && PYTHONPATH="$(echo /out/usr/local/lib/python3*/site-packages)" \
        /out/usr/local/bin/peregrine --version

# --- ship -------------------------------------------------------------------
# A minimal stage holding the installed server and its wheel, for an
# application image to COPY --from.
FROM scratch AS export
COPY --from=build /out/ /
