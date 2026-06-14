#!/bin/bash

# This script was copied from https://gist.github.com/jpasquier/65e95707089f79d9406fa8e7f9e96eb0

set -euo pipefail

# ── Preconditions ────────────────────────────────────────────────────────────

export DEBIAN_FRONTEND=noninteractive

ensure_trixie_components() {
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    if grep -qE '^deb .* trixie' "$f" 2>/dev/null; then
      sed -i -E 's#^(deb\s+\S+\s+\S+\s+(trixie|trixie-updates|trixie-security)\s+main)(\s.*)?$#\1 contrib non-free non-free-firmware#' "$f"
    fi
  done
}

ensure_trixie_components

apt-get update
apt-get install -y \
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
    ca-certificates \
    dpkg \
    fakeroot \
    libspa-0.2-bluetooth

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

# Architecture / multiarch triplet
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
TRIPLET="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -dumpmachine || echo "${ARCH}-linux-gnu")"

echo "Detected libspa/pipewire version:"
echo "  Debian package version: ${DEB_VER}"
echo "  Upstream (tarball) ver: ${UPSTREAM_VER}"
echo

cd "$BUILD_DIR"

wget -O "pipewire_${UPSTREAM_VER}.orig.tar.bz2" \
  "https://deb.debian.org/debian/pool/main/p/pipewire/pipewire_${UPSTREAM_VER}.orig.tar.bz2"
tar xf "pipewire_${UPSTREAM_VER}.orig.tar.bz2"
cd "pipewire-${UPSTREAM_VER}"

meson setup build \
  -Dbluez5=enabled \
  -Dbluez5-codec-aac=enabled
ninja -C build

f=$(find build -type f -name 'libspa-codec-bluez5-aac.so' | head -n1)
if [ -z "${f}" ]; then
  echo "libspa-codec-bluez5-aac.so not found under build/" >&2
  echo "Available bluez5 codec artifacts:" >&2
  find build -type f -name 'libspa-codec-bluez5-*.so' -print || true
  exit 1
fi

cp "$f" "$BUILD_DIR/libspa-codec-bluez5-aac.so"
ls -l "$BUILD_DIR/libspa-codec-bluez5-aac.so"

# Ensure the .so exists
if [ ! -f "$BUILD_DIR/libspa-codec-bluez5-aac.so" ]; then
  echo "Failed to build libspa-codec-bluez5-aac.so." >&2
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
