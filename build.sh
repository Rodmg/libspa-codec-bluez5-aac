#!/bin/bash

# This script was copied from https://gist.github.com/jpasquier/65e95707089f79d9406fa8e7f9e96eb0

set -euo pipefail

# ── Preconditions ────────────────────────────────────────────────────────────

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is required." >&2; exit 1; }; }
need docker
need dpkg-deb
need fakeroot
need dpkg-architecture

if ! docker info > /dev/null 2>&1; then
  echo "This script uses docker, and it isn't running - please start docker and try again!" >&2
  exit 1
fi

# ── Detect versions from the system ──────────────────────────────────────────

# Prefer the installed libspa-0.2-bluetooth version; fallback to pipewire if needed.
DEB_VER="$(dpkg-query -W -f='${Version}\n' libspa-0.2-bluetooth 2>/dev/null || true)"
if [ -z "${DEB_VER}" ] || [ "${DEB_VER}" = "unknown" ]; then
  DEB_VER="$(dpkg-query -W -f='${Version}\n' pipewire 2>/dev/null || true)"
fi

if [ -z "${DEB_VER}" ] || [ "${DEB_VER}" = "unknown" ]; then
  echo "Could not detect installed PipeWire/SPA version (libspa-0.2-bluetooth or pipewire). Install PipeWire first." >&2
  exit 1
fi

# Upstream tarball version (strip Debian revision like '-1', '-1+b1', etc.)
UPSTREAM_VER="${DEB_VER%%-*}"
# Some Debian versions may not have a hyphen; ensure UPSTREAM_VER non-empty.
if [ -z "${UPSTREAM_VER}" ]; then
  UPSTREAM_VER="${DEB_VER}"
fi


# ── Setup ────────────────────────────────────────────────────────────────────

CURRENT_DIR="$(pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/build-pipewire-aac.XXXXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

IMAGE_NAME="pipewire-aac"
CONTAINER_NAME="pipewire-aac"

# Architecture / multiarch triplet
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
TRIPLET="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -dumpmachine || echo "${ARCH}-linux-gnu")"

echo "Detected libspa/pipewire version:"
echo "  Debian package version: ${DEB_VER}"
echo "  Upstream (tarball) ver: ${UPSTREAM_VER}"
echo

# ── Dockerfile ───────────────────────────────────────────────────────────────

# Keep variables inside the Dockerfile literal (use ARG/ENV inside Dockerfile).
cat > "$BUILD_DIR/Dockerfile" << 'EOL'
FROM debian:trixie-slim

ARG PIPEWIRE_VER
ENV PIPEWIRE_VER=${PIPEWIRE_VER}
ENV DEBIAN_FRONTEND=noninteractive
ENV USER=pipewire

# Enable contrib + non-free (+ non-free-firmware) for trixie
RUN printf "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware\n\
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware\n\
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware\n" > /etc/apt/sources.list

# Update and install necessary dependencies (build + fetch tools)
RUN apt-get update && apt-get install -y \
    build-essential \
    meson ninja-build pkgconf \
    libbluetooth-dev \
    libasound2-dev \
    libdbus-1-dev \
    libglib2.0-dev \
    libudev-dev \
    libsbc-dev \
    libopus-dev \
    liblc3-dev \
    libldacbt-enc-dev \
    libfdk-aac-dev \
    git \
    wget \
    python3 \
 && rm -rf /var/lib/apt/lists/*

# Create a non-root user and a drop location for the built .so
RUN useradd -ms /bin/bash "$USER" \
 && mkdir /pipewire-aac \
 && chown "$USER":"$USER" /pipewire-aac

USER $USER
WORKDIR /home/$USER

# Fetch the exact upstream PipeWire tarball
RUN mkdir -p /home/$USER/build/pipewire-aac
WORKDIR /home/$USER/build/pipewire-aac
RUN wget -O pipewire_${PIPEWIRE_VER}.orig.tar.bz2 \
  "https://deb.debian.org/debian/pool/main/p/pipewire/pipewire_${PIPEWIRE_VER}.orig.tar.bz2"
RUN tar xf pipewire_${PIPEWIRE_VER}.orig.tar.bz2
WORKDIR /home/$USER/build/pipewire-aac/pipewire-${PIPEWIRE_VER}

# Configure only the BlueZ5 AAC codec and build
RUN meson setup build \
  -Dbluez5=enabled \
  -Dbluez5-codec-aac=enabled
RUN ninja -C build

# Copy the built library to the shared location (robust to path changes)
RUN bash -lc 'set -euo pipefail; \
  f=$(find build -type f -name libspa-codec-bluez5-aac.so | head -n1); \
  if [ -z "$f" ]; then \
    echo "libspa-codec-bluez5-aac.so not found under build/"; \
    echo "Available bluez5 codec artifacts:"; \
    find build -type f -name "libspa-codec-bluez5-*.so" -print || true; \
    exit 1; \
  fi; \
  install -Dm644 "$f" /pipewire-aac/libspa-codec-bluez5-aac.so; \
  ls -l /pipewire-aac/libspa-codec-bluez5-aac.so'
EOL

# ── Build and extract ────────────────────────────────────────────────────────

docker build --network=host --build-arg "PIPEWIRE_VER=${UPSTREAM_VER}" -t "$IMAGE_NAME" "$BUILD_DIR"

# Create a container and run it (it will exit immediately, which is fine for docker cp)
docker run --name "$CONTAINER_NAME" "$IMAGE_NAME" || true

# Copy the binary from the container to the BUILD_DIR
docker cp "$CONTAINER_NAME":/pipewire-aac/libspa-codec-bluez5-aac.so "$BUILD_DIR/"

# Stop and remove the container; remove the image
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker image rm "$IMAGE_NAME" >/dev/null 2>&1 || true

# Ensure the .so exists
if [ ! -f "$BUILD_DIR/libspa-codec-bluez5-aac.so" ]; then
  echo "Failed to extract libspa-codec-bluez5-aac.so from the container." >&2
  exit 1
fi

# Fix ownership if run with sudo
if [ "${SUDO_USER:-}" != "" ] && [ "$EUID" -eq 0 ]; then
  chown "$SUDO_USER:$SUDO_USER" "$BUILD_DIR/libspa-codec-bluez5-aac.so"
fi

# ── Package .deb ─────────────────────────────────────────────────────────────

PKG_NAME="libspa-codec-bluez5-aac_${UPSTREAM_VER}_${ARCH}"
PKG_DIR="$BUILD_DIR/$PKG_NAME"

mkdir -p "$PKG_DIR/DEBIAN" \
         "$PKG_DIR/usr/lib/$TRIPLET/spa-0.2/bluez5"

# Place the built .so in the Debian-expected location
cp "$BUILD_DIR/libspa-codec-bluez5-aac.so" \
   "$PKG_DIR/usr/lib/$TRIPLET/spa-0.2/bluez5/libspa-codec-bluez5-aac.so"

# Control file
# - Package version = upstream (e.g., 1.4.2) — it's the plugin's build version.
# - Depends on libspa-0.2-bluetooth (>= DEB_VER) to match the exact ABI we built against.
cat > "$PKG_DIR/DEBIAN/control" <<CTRL
Package: libspa-codec-bluez5-aac
Version: ${UPSTREAM_VER}
Section: libs
Priority: optional
Architecture: ${ARCH}
Depends: libfdk-aac2t64 (>= 2.0.3), libspa-0.2-bluetooth (>= ${DEB_VER})
Maintainer: Your Name <you@example.com>
Description: AAC codec plugin for PipeWire BlueZ5 (built from PipeWire ${UPSTREAM_VER})
 Installs /usr/lib/${TRIPLET}/spa-0.2/bluez5/libspa-codec-bluez5-aac.so
CTRL

# Build the package
fakeroot dpkg-deb --build "$PKG_DIR" >/dev/null

# Move final .deb to the original working directory
FINAL_DEB="${PKG_DIR}.deb"
mv -f "$FINAL_DEB" "$CURRENT_DIR/"

# Fix ownership of the .deb if run with sudo
if [ "${SUDO_USER:-}" != "" ] && [ "$EUID" -eq 0 ]; then
  chown "$SUDO_USER:$SUDO_USER" "$CURRENT_DIR/$(basename "$FINAL_DEB")"
fi

echo
echo "✅ Built: $(basename "$FINAL_DEB")"
echo "   Location: $CURRENT_DIR/$(basename "$FINAL_DEB")"
echo "   To install: sudo apt install ./$(basename "$FINAL_DEB")"
