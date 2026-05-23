# prusaslicer-docker — headless PrusaSlicer, source-built from upstream tags.
#
# Why this image exists:
# Prusa stopped publishing Linux AppImages on GitHub Releases after
# PrusaSlicer 2.8.1 (Sep 2024). The 2.9.x line ships Linux only via
# Flathub — the wrong tool inside a container. This Dockerfile follows
# upstream's `doc/How to build - Linux et al.md` to produce a self-
# contained binary suitable for headless CLI use.
#
# Bump procedure: change PRUSASLICER_REF below, or pass
# `--build-arg PRUSASLICER_REF=version_X.Y.Z` at build time. The
# repository's CI also auto-rebuilds when a newer upstream tag drops.

ARG PRUSASLICER_REF=version_2.9.5

# ──────────────────────────────────────────────────────────────────────
# Stage 1 — builder (Ubuntu 24.04 is upstream's tested Linux target)
# ──────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

ARG PRUSASLICER_REF
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# C.UTF-8 locale is required: CMake's deps extract tarballs via libarchive,
# which refuses non-ASCII filenames when the locale isn't UTF-8 (Boost
# 1.83's tarball trips this).

# Build prereqs:
# - upstream-listed: `autoconf`, `cmake`, `libglu1-mesa-dev`, `libgtk-3-dev`,
#   `libdbus-1-dev`, `libwebkit2gtk-4.1-dev`, `texinfo`
# - the full autotools trio (`autoconf` + `automake` + `libtool`) so MPFR's
#   `autoreconf -i` works — without `automake` you get "aclocal failed: 2",
#   without `libtool` you get "libtoolize failed: 2"
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git \
        build-essential cmake autoconf automake libtool m4 pkg-config patch file texinfo \
        libglu1-mesa-dev libgtk-3-dev libdbus-1-dev libwebkit2gtk-4.1-dev \
        wget curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "$PRUSASLICER_REF" \
        https://github.com/prusa3d/PrusaSlicer.git . \
    && git rev-parse HEAD > /src/.builtfrom \
    && echo "Building from $(cat /src/.builtfrom) ($PRUSASLICER_REF)"

# Stage A — bundled deps (statically linked). The expensive step
# (~30–60 min cold on 4 cores) but cached as long as PRUSASLICER_REF and
# the apt list above don't change.
WORKDIR /src/deps/build
RUN cmake .. -DDEP_WX_GTK3=ON && make -j"$(nproc)"

# Stage B — PrusaSlicer itself, headless build.
# SLIC3R_GUI=no drops the wxWidgets link; SLIC3R_STATIC=1 statically links
# the bundled deps. Target name is `PrusaSlicer` (capital P, capital S) —
# the OUTPUT_NAME is the lowercase `prusa-slicer` binary, which is a
# common pitfall (`make prusa-slicer` -> "No rule to make target").
WORKDIR /src/build
RUN cmake .. \
        -DSLIC3R_STATIC=1 \
        -DSLIC3R_GTK=3 \
        -DSLIC3R_GUI=no \
        -DSLIC3R_PCH=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH=/src/deps/build/destdir/usr/local \
    && make -j"$(nproc)" PrusaSlicer

# Sanity-check that the binary built and runs.
RUN test -x /src/build/src/prusa-slicer \
    && /src/build/src/prusa-slicer --help 2>&1 | head -1

# ──────────────────────────────────────────────────────────────────────
# Stage 2 — slim runtime
# ──────────────────────────────────────────────────────────────────────
FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive

# Runtime libs (just enough for the headless binary; no GTK/WebKit since
# SLIC3R_GUI=no drops those links). xvfb is a belt-and-suspenders fallback
# in case any path tries to open a display.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xvfb \
        libglu1-mesa libsdl2-2.0-0 libopengl0 libgl1 \
        libegl1 libgles2 libdbus-1-3 \
        libgomp1 \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Layout: PrusaSlicer at /opt/prusaslicer/bin/, resources at
# /opt/prusaslicer/resources/. At runtime the binary resolves resources
# via `<binary>/../resources` (boost::dll::program_location(), Linux,
# non-FHS build) — there's no env-var override, so this layout matters.
# See src/CLI/Setup.cpp in upstream.
RUN mkdir -p /opt/prusaslicer/bin
COPY --from=builder /src/build/src/prusa-slicer /opt/prusaslicer/bin/prusa-slicer
COPY --from=builder /src/resources              /opt/prusaslicer/resources
COPY --from=builder /src/.builtfrom             /opt/prusaslicer/.builtfrom

# AGPLv3 compliance: PrusaSlicer is AGPLv3. Distributing its binary
# triggers AGPLv3 §§ 5–6 (convey the source, preserve the license
# notice). Ship the verbatim LICENSE and a SOURCE pointer file that
# names the exact upstream commit so corresponding source is one click
# away.
ARG PRUSASLICER_REF
COPY --from=builder /src/LICENSE                /opt/prusaslicer/LICENSE
RUN SHA=$(cat /opt/prusaslicer/.builtfrom) \
    && printf '%s\n' \
        "This image bundles PrusaSlicer." \
        "" \
        "License:       GNU Affero General Public License v3 (see ./LICENSE)." \
        "Upstream:      https://github.com/prusa3d/PrusaSlicer" \
        "Built from:    tag ${PRUSASLICER_REF}, commit ${SHA}" \
        "Source code:   https://github.com/prusa3d/PrusaSlicer/tree/${SHA}" \
        "" \
        "Per AGPLv3 § 6, the corresponding source code for the prusa-slicer" \
        "binary in this image is the upstream repository at the commit above." \
        > /opt/prusaslicer/SOURCE

# Put `prusa-slicer` on PATH.
RUN ln -s /opt/prusaslicer/bin/prusa-slicer /usr/local/bin/prusa-slicer \
    && /opt/prusaslicer/bin/prusa-slicer --help 2>&1 | head -1 \
    && echo "Built from $(cat /opt/prusaslicer/.builtfrom)"

# Default to printing the help banner. Users typically override (e.g.
# `docker run image prusa-slicer --slice ...`) or `FROM` this image.
CMD ["prusa-slicer", "--help"]
