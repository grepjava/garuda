# Builds the peregrine binary against one specific CPython, and ships it alone.
#
# Peregrine embeds libpython rather than talking to it over a socket, so the
# binary is bound to the interpreter it was linked against. The way to get that
# right is to build it *inside* the runtime image: the libpython it links is
# then, by construction, the one it will find at run time.
#
#   docker build -t peregrine:3.14 .
#   docker build -t peregrine:3.13 --build-arg PYTHON_IMAGE=python:3.13-slim .
#
# The base image decides everything: which CPython is embedded, and whether
# --free-threaded is available at all. The official python images have no
# free-threaded variant, so a base that provides one has to be built or brought
# (see INSTALLATION.md); against an ordinary one --free-threaded is refused.
#
# The result is a scratch-thin layer holding the binary and the Swift runtime
# it needs, meant to be consumed by an application image:
#
#   COPY --from=peregrine:3.14 /out/ /usr/local/
#
# Building the server once and copying it in keeps a Swift toolchain -- and
# several minutes of compilation -- out of every application's deploy.

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
# would put a second python3-embed.pc on the pkg-config path. The base image
# already provides the headers and the .pc file for the interpreter that
# matters.
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
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests

# Point pkg-config at the image's own interpreter explicitly, and prove it
# resolved to that one before spending five minutes compiling against it.
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
RUN pkg-config --modversion python3-embed && pkg-config --libs python3-embed

RUN swift build -c release --scratch-path /tmp/build \
    && install -D -m 0755 /tmp/build/release/peregrine /out/bin/peregrine

# The Swift runtime is dynamically linked and is not in the runtime image, so
# the few libraries actually used travel with the binary. Foundation is not
# among them -- peregrine does not link it -- which is most of why this is small.
#
# The rpath is then rewritten to $ORIGIN so the pair is relocatable: whoever
# consumes this needs one COPY and no ldconfig, no LD_LIBRARY_PATH and no
# knowledge of where the toolchain happened to live when it was built.
RUN mkdir -p /out/lib/swift/linux \
    && for so in $(ldd /out/bin/peregrine | awk '/swift|Swift/ {print $3}'); do \
           cp -L "$so" /out/lib/swift/linux/; \
       done \
    && patchelf --set-rpath '$ORIGIN/../lib/swift/linux' /out/bin/peregrine \
    && for so in /out/lib/swift/linux/*.so*; do patchelf --set-rpath '$ORIGIN' "$so"; done

# Prove the relocated binary runs with nothing but the base image around it,
# here, rather than leaving it to fail in the application's image.
RUN /out/bin/peregrine --version

# --- ship -------------------------------------------------------------------
# A minimal stage holding nothing but the binary and its Swift libraries, for an
# application image to COPY --from.
FROM scratch AS export
COPY --from=build /out/ /
