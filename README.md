# Chrome OS RMA Shim Bootloader - Gentoo Edition

Shimboot is a collection of scripts for patching a Chrome OS RMA shim to serve as a bootloader for a standard Linux distribution. This fork adds **Gentoo Linux** support to shimboot, allowing you to boot Gentoo on a Chromebook without modifying the firmware.

This fork is based on the original [shimboot](https://github.com/ading2210/shimboot) project by ading2210.

## Features

- **Run Gentoo Linux** on a Chromebook via RMA shim
- **Does not modify the firmware** - safe for enterprise enrolled devices
- **OpenRC init system** - better compatibility with ChromeOS kernel
- **XFCE Desktop** with LightDM (default)
- **Optional encryption** with LUKS2
- **Multiple architectures** - x86_64 and ARM64 supported

## Table of Contents

- [Features](#features)
- [About](#about)
  - [Partition Layout](#partition-layout)
  - [Kernel Version](#kernel-version)
- [Status](#status)
  - [Device Compatibility Table](#device-compatibility-table)
- [Usage](#usage)
  - [Prerequisites](#prerequisites)
  - [Build Instructions](#build-instructions)
  - [Building Gentoo](#building-gentoo)
  - [Booting the Image](#booting-the-image)
- [FAQ](#faq)
- [Copyright](#copyright)

## About

Chrome OS RMA shims are bootable disk images designed to run diagnostic utilities on Chromebooks, even on enterprise enrolled devices. Unfortunately for Google, the root filesystem of the RMA shim is not verified. This allows us to replace it with any Linux distribution.

Simply replacing the shim's rootfs doesn't work, as it boots in an environment friendly to the RMA shim, not regular Linux distros. A separate bootloader is required to transition from the shim environment to the main rootfs.

### Why Gentoo?

Gentoo offers several advantages for shimboot:

- **Portage package manager** - configured to use official Gentoo binary packages for much faster builds
- **OpenRC init system** - more compatible with ChromeOS kernel than systemd
- **Rolling release** - always up-to-date packages
- **Flexible USE flags** - customize your system exactly

### Partition Layout

1. 1MB dummy stateful partition
2. 32MB Chrome OS kernel
3. 20MB bootloader
4. The rootfs partitions fill the rest of the disk

Note that rootfs partitions have to be named `shimboot_rootfs:<partname>` for the bootloader to recognize them.

### Kernel Version

The default kernel version for supported boards:

| Board | Default Kernel Version |
|-------|----------------------|
| dedede | 5.4.85 |
| octopus | 4.14.3137 |
| zork | 5.4.85 |
| hatch | 4.19.3369 |
| grunt | 4.19.3028 |
| nissa | 5.4.85 |
| snappy | 4.14.2419 |

You can specify a different kernel version with `kernel_ver=<version>`.

## Status

Driver support depends on the device you are using shimboot on. The `patch_rootfs.sh` script copies all firmware and drivers from the shim and recovery image into the rootfs.

### Device Compatibility Table

| Board Name | X11 | Wifi | Speakers | Backlight | Touchscreen | 3D Accel | Bluetooth | Webcam |
|------------|-----|------|----------|-----------|-------------|----------|-----------|--------|
| dedede | yes | yes | no | yes | yes | yes | yes | yes |
| octopus | yes | yes | yes | yes | yes | yes | yes | yes |
| nissa | yes | yes | no | yes | yes | yes | yes | yes |
| zork | yes | yes | no | yes | yes | yes | yes | yes |
| grunt | yes | yes | no | yes | yes | yes | yes | yes |
| hatch | yes | yes | no | yes | yes | yes | yes | yes |
| snappy | yes | yes | yes | yes | yes | yes | yes | yes |

On all devices, expect:
- Zram (compressed memory)
- Disk compression with squashfs

On all devices:
- Suspend is disabled by the ChromeOS kernel
- Swap is disabled by the ChromeOS kernel

## Usage

### Prerequisites

- A separate Linux PC for the build process (preferably Debian-based)
- At least 40GB of free disk space (less CPU time is needed because Gentoo uses binary packages where possible)
- A USB drive that is at least 8GB in size (16GB recommended)

### Build Instructions

1. Find the board name of your Chromebook from [cros.download](https://cros.download/recovery)
2. Clone this repository and cd into it
3. Run the build command

### Building Gentoo

```bash
# Build Gentoo with default settings (XFCE, LightDM, kernel 5.4.85 for dedede)
# Gentoo packages are pulled from the official binhost whenever possible.
sudo ./build_complete.sh dedede distro=gentoo

# Use a specific kernel version
sudo ./build_complete.sh dedede distro=gentoo kernel_ver=5.4.85

# Refuse to compile from source if a matching binary package is unavailable
sudo ./build_complete.sh dedede distro=gentoo gentoo_binpkg_only=1

# Compress the final image
sudo ./build_complete.sh dedede distro=gentoo compress_img=1

# Use LUKS2 encryption
sudo ./build_complete.sh dedede distro=gentoo luks=1

# Build for ARM Chromebook
sudo ./build_complete.sh corsola distro=gentoo arch=arm64
```

### Booting the Image

1. Flash the shimboot image to a USB drive using dd or the Chromebook Recovery Utility
2. Enable developer mode on your Chromebook
3. If the Chromebook is enrolled, follow [Sh1mmer instructions](https://sh1mmer.me)
4. Plug in the USB and enter recovery mode
5. Boot into Gentoo and log in with `user/user`
6. Expand the rootfs: `sudo expand_rootfs`
7. Change your password: `passwd user`

## Supported Distros

This fork supports the following distributions:

- **Gentoo Linux** (OpenRC) - Primary focus of this fork
- Debian 12 (Bookworm)
- Debian 13 (Trixie)
- Debian Unstable (Sid)
- Alpine Linux

```bash
# Gentoo (this fork's default)
sudo ./build_complete.sh dedede distro=gentoo

# Debian (default upstream)
sudo ./build_complete.sh dedede

# Alpine
sudo ./build_complete.sh dedede distro=alpine
```

## FAQ

### Does Gentoo compile everything during the build?

No. This fork configures `/etc/portage/binrepos.conf/gentoobinhost.conf` and `EMERGE_DEFAULT_OPTS` so `emerge` downloads official Gentoo binary packages (`--getbinpkg`) by default. The normal mode prefers binpkgs and only falls back to source if the binhost does not have a matching package. If you want the build to fail instead of compiling any missing package, add `gentoo_binpkg_only=1`.

### Why does Gentoo use OpenRC instead of systemd?

The ChromeOS kernel has compatibility issues with systemd's mount handling. OpenRC provides a simpler init system that works more reliably with the shimboot approach. Additionally, OpenRC is the default init system for Gentoo and integrates well with Gentoo's init system configuration.

### How is Gentoo different from other distros?

- Uses Portage package manager (source-based)
- Uses official Gentoo binary packages during installation whenever possible
- Uses OpenRC init system
- Rolling release model

### Can I use a different desktop environment?

Currently, this fork is configured for **XFCE with LightDM** as the default for Gentoo. The build scripts can be modified to support other desktop environments.

### GPU acceleration isn't working

If your kernel version is too old, the standard Mesa drivers may fail. You may need to install `mesa-amber` drivers.

### How can I encrypt my Shimboot USB?

```bash
sudo ./build_complete.sh dedede distro=gentoo luks=1
```

## Copyright

Shimboot is licensed under the GNU GPL v3.

Original work by [ading2210](https://github.com/ading2210). Gentoo support additions by [foxdefox-wq](https://github.com/foxdefox-wq).

This project includes code and concepts from the original [shimboot project](https://github.com/ading2210/shimboot).