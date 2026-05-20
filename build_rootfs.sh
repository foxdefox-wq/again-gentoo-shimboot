#!/bin/bash

#build the rootfs for various distros

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path release_name"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages - The packages that will be installed in place of task-xfce-desktop."
  echo "  hostname        - The hostname for the new rootfs."
  echo "  enable_root     - Enable the root user."
  echo "  root_passwd     - The root password. This only has an effect if enable_root is set."
  echo "  username        - The unprivileged user name for the new rootfs."
  echo "  user_passwd     - The password for the unprivileged user."
  echo "  disable_base    - Disable the base packages such as zram, cloud-utils, and command-not-found."
  echo "  arch            - The CPU architecture to build the rootfs for."
  echo "  distro          - The Linux distro to use. This should be 'debian', 'ubuntu', 'alpine', or 'gentoo'."
  echo "  gentoo_binpkg_only - Gentoo only: set to 1 to fail instead of compiling packages missing from the binhost."
  echo "If you do not specify the hostname and credentials, you will be prompted for them later."
}

assert_root
assert_deps "realpath findmnt wget tar bzip2 xz git"
parse_args "$@"

rootfs_dir=$(realpath -m "${1}")
release_name="${2}"
packages="${args['custom_packages']-task-xfce-desktop}"
arch="${args['arch']-amd64}"
distro="${args['distro']-debian}"
chroot_mounts="proc sys dev run"

mkdir -p $rootfs_dir

unmount_all() {
  for mountpoint in $chroot_mounts; do
    umount -l "$rootfs_dir/$mountpoint" 2>/dev/null || true
  done
}

need_remount() {
  local target="$1"
  local mnt_options="$(findmnt -T "$target" 2>/dev/null | tail -n1 | rev | cut -f1 -d' '| rev)"
  echo "$mnt_options" | grep -e "noexec" -e "nodev"
}

do_remount() {
  local target="$1"
  local mountpoint="$(findmnt -T "$target" 2>/dev/null | tail -n1 | cut -f1 -d' ')"
  mount -o remount,dev,exec "$mountpoint"
}

if [ "$(need_remount "$rootfs_dir")" ]; then
  do_remount "$rootfs_dir"
fi

if [ "$distro" = "debian" ]; then
  print_info "bootstraping debian chroot"
  # Check if debootstrap is available
  if ! command -v debootstrap &> /dev/null; then
    print_error "debootstrap is required for Debian/Ubuntu. Please install it first."
    exit 1
  fi
  debootstrap --arch $arch --components=main,contrib,non-free,non-free-firmware "$release_name" "$rootfs_dir" http://deb.debian.org/debian/
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "ubuntu" ]; then 
  print_info "bootstraping ubuntu chroot"
  # Check if debootstrap is available
  if ! command -v debootstrap &> /dev/null; then
    print_error "debootstrap is required for Debian/Ubuntu. Please install it first."
    exit 1
  fi
  repo_url="http://archive.ubuntu.com/ubuntu"
  if [ "$arch" = "amd64" ]; then
    repo_url="http://archive.ubuntu.com/ubuntu"
  else 
    repo_url="http://ports.ubuntu.com"
  fi
  debootstrap --arch $arch "$release_name" "$rootfs_dir" "$repo_url"
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "alpine" ]; then
  print_info "downloading alpine package list"
  pkg_list_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
  pkg_data="$(wget -qO- "$pkg_list_url" | grep "apk-tools-static")"
  pkg_url="$pkg_list_url$(echo "$pkg_data" | grep -oP '"[^"]+\.apk"' | tr -d '"' | tail -1)"

  print_info "downloading and extracting apk-tools-static"
  pkg_extract_dir="/tmp/apk-tools-static"
  pkg_dl_path="$pkg_extract_dir/pkg.apk"
  apk_static="$pkg_extract_dir/sbin/apk.static"
  mkdir -p "$pkg_extract_dir"
  wget -q "$pkg_url" -O "$pkg_dl_path"
  tar --warning=no-unknown-keyword -xzf "$pkg_dl_path" -C "$pkg_extract_dir"

  print_info "bootstraping alpine chroot"
  real_arch="x86_64"
  if [ "$arch" = "arm64" ]; then 
    real_arch="aarch64"
  fi
  $apk_static \
    --arch $real_arch \
    -X http://dl-cdn.alpinelinux.org/alpine/$release_name/main/ \
    -U --allow-untrusted \
    --root "$rootfs_dir" \
    --initdb add alpine-base
  chroot_script="/opt/setup_rootfs_alpine.sh"

elif [ "$distro" = "gentoo" ]; then
  print_info "bootstraping gentoo chroot"
  
  # Determine Gentoo architecture
  if [ "$arch" = "amd64" ]; then
    gentoo_arch="amd64"
  elif [ "$arch" = "arm64" ]; then
    gentoo_arch="arm64"
  else
    print_error "Unsupported architecture for Gentoo: $arch"
    exit 1
  fi
  
  # Determine cache directory (use data_dir from the caller, or default to ./data)
  stage3_cache_dir="$(dirname "$rootfs_dir")"
  mkdir -p "$stage3_cache_dir"
  
  # Gentoo autobuilds directory
  stage3_dir="https://distfiles.gentoo.org/releases/$gentoo_arch/autobuilds/current-stage3-${gentoo_arch}-openrc"
  
  # Always fetch fresh directory listing
  print_info "Fetching stage3 tarball list from Gentoo mirrors..."
  stage3_html="/tmp/gentoo-stage3-list.html"
  rm -f "$stage3_html"
  wget -q "$stage3_dir/" -O "$stage3_html"
  
  if [ ! -s "$stage3_html" ]; then
    print_error "Failed to fetch directory listing"
    exit 1
  fi
  
  # Extract all .tar.xz filenames, excluding .asc signature files
  # Sort by timestamp (newest first) to get the latest
  stage3_file=$(grep -oE 'stage3-[^"<]+\.tar\.xz' "$stage3_html" | grep -v '\.asc' | sort -r | head -1)
  
  if [ -z "$stage3_file" ]; then
    print_error "Failed to find stage3 tarball in directory listing"
    rm -f "$stage3_html"
    exit 1
  fi
  
  stage3_full_url="${stage3_dir}/${stage3_file}"
  stage3_tarball="${stage3_cache_dir}/${stage3_file}"
  
  print_info "Found stage3 tarball: $stage3_file"
  print_info "Downloading from: $stage3_full_url"
  
  # Use cached tarball if it exists and is valid
  if [ -f "$stage3_tarball" ]; then
    print_info "Found cached tarball at $stage3_tarball, validating..."
    if xz -t "$stage3_tarball" 2>/dev/null; then
      print_info "Cached tarball is valid, skipping download"
    else
      print_info "Cached tarball is corrupt, re-downloading..."
      rm -f "$stage3_tarball"
    fi
  fi
  
  # Download if not cached (or cache was invalid)
  if [ ! -f "$stage3_tarball" ]; then
    print_info "Downloading stage3 tarball (this may take a few minutes)..."
    if ! wget --progress=dot:giga "$stage3_full_url" -O "$stage3_tarball" 2>&1; then
      print_error "Failed to download stage3 tarball"
      rm -f "$stage3_tarball" "$stage3_html"
      exit 1
    fi
    
    # Validate the downloaded file is a valid xz archive
    print_info "Validating tarball..."
    if ! xz -t "$stage3_tarball" 2>/dev/null; then
      print_error "Downloaded file is not a valid xz archive"
      print_info "File size: $(ls -la "$stage3_tarball" | awk '{print $5}') bytes"
      rm -f "$stage3_tarball" "$stage3_html"
      exit 1
    fi
  fi
  
  print_info "Extracting stage3 tarball (this may take a while)..."
  tar xpf "$stage3_tarball" --xattrs-include='*/*' --numeric-owner -C "$rootfs_dir" 2>&1 | tail -30
  
  # Verify extraction worked
  if [ ! -f "$rootfs_dir/etc/passwd" ]; then
    print_error "Stage3 extraction failed - /etc/passwd not found"
    print_info "Contents of rootfs:"
    ls -la "$rootfs_dir/"
    rm -f "$stage3_html"
    exit 1
  fi
  
  print_info "Stage3 extraction complete"
  
  # Clean up listing (keep the tarball for caching)
  rm -f "$stage3_html"
  
  chroot_script="/opt/setup_rootfs_gentoo.sh"

else
  print_error "'$distro' is an invalid distro choice."
  exit 1
fi

print_info "copying rootfs setup scripts"
cp -arv rootfs/* "$rootfs_dir" 2>/dev/null || true
cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf" 2>/dev/null || true

# Clean up Windows Zone.Identifier files
find "$rootfs_dir" -name "*.Zone.Identifier" -delete 2>/dev/null || true

print_info "creating bind mounts for chroot"
trap unmount_all EXIT
for mountpoint in $chroot_mounts; do
  mkdir -p "$rootfs_dir/$mountpoint"
  mount --make-rslave --rbind "/${mountpoint}" "${rootfs_dir}/$mountpoint" 2>/dev/null || true
done

hostname="${args['hostname']}"
root_passwd="${args['root_passwd']}"
enable_root="${args['enable_root']}"
username="${args['username']}"
user_passwd="${args['user_passwd']}"
disable_base="${args['disable_base']}"
gentoo_binpkg_only="${args['gentoo_binpkg_only']}"

chroot_command="$chroot_script \
  '$DEBUG' '$release_name' '$packages' \
  '$hostname' '$root_passwd' '$username' \
  '$user_passwd' '$enable_root' '$disable_base' \
  '$arch' '$gentoo_binpkg_only'"

LC_ALL=C chroot $rootfs_dir /bin/sh -c "${chroot_command}"

trap - EXIT
unmount_all

print_info "rootfs has been created"
