# libspa-codec-bluez5-aac

This repository contains a Docker-powered build helper for creating the `libspa-codec-bluez5-aac` PipeWire BlueZ5 AAC codec plugin as a Debian package.

The build script was originally sourced from https://gist.github.com/jpasquier/65e95707089f79d9406fa8e7f9e96eb0.

## Overview

The `build.sh` script:

- detects the installed `libspa-0.2-bluetooth` or `pipewire` version
- downloads the matching upstream PipeWire source tarball from Debian
- builds the `bluez5` AAC codec plugin inside a Debian-based Docker container
- extracts the built `libspa-codec-bluez5-aac.so`
- packages it into a `.deb` file for Debian/Ubuntu-style systems

## Prerequisites

Before running the build script, make sure you have the following installed:

- Docker
- `dpkg-deb`
- `fakeroot`
- `dpkg-architecture`

Docker must be running when you execute the script.

## Build

Run the build helper from the repository root:

```bash
./build.sh
```

The script will produce a `.deb` package in the current directory, named like:

```bash
libspa-codec-bluez5-aac_<version>_<arch>.deb
```

## Install

After the package is built, install it with:

```bash
sudo apt install ./libspa-codec-bluez5-aac_<version>_<arch>.deb
```

## Notes

- The build script sources the PipeWire tarball version from the installed Debian package version.
- The produced package depends on `libspa-0.2-bluetooth` and `libfdk-aac2t64`.
- The built shared object is installed to:

```bash
/usr/lib/<multiarch>/spa-0.2/bluez5/libspa-codec-bluez5-aac.so
```

## License

This repository does not include upstream source code. It provides a build helper script only.
