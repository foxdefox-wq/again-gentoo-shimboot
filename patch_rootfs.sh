#!/bin/bash

#patch the target rootfs to add any needed drivers

. ./common.sh
. ./image_utils.sh

print_help() {
  echo "Usage: ./patch_rootfs.sh shim_path reco_path rootfs_dir"
}

assert_root
assert_deps "git gunzip depmod"
assert_args "$3"

copy_modules() {
  local shim_rootfs=$(realpath -m $1)
  local reco_rootfs=$(realpath -m $2)
  local target_rootfs=$(realpath -m $3)

  rm -rf "${target_rootfs}/lib/modules"
  mkdir -p "${target_rootfs}/lib/modules"

  # Merge modules from both recovery and shim images. The recovery image often
  # has the complete ChromeOS hardware driver set, while the shim can be more
  # minimal. Input devices on Chromebooks (cros_ec keyboard, I2C-HID touchpads,
  # touchscreens) may live only in the recovery module tree.
  if [ -d "${reco_rootfs}/lib/modules" ]; then
    cp -a "${reco_rootfs}/lib/modules/." "${target_rootfs}/lib/modules/" 2>/dev/null || true
  fi
  if [ -d "${shim_rootfs}/lib/modules" ]; then
    cp -a "${shim_rootfs}/lib/modules/." "${target_rootfs}/lib/modules/" 2>/dev/null || true
  fi

  mkdir -p "${target_rootfs}/lib/firmware"
  cp -a --remove-destination "${shim_rootfs}/lib/firmware/." "${target_rootfs}/lib/firmware/" 2>/dev/null || true
  cp -a --remove-destination "${reco_rootfs}/lib/firmware/." "${target_rootfs}/lib/firmware/" 2>/dev/null || true

  # ChromeOS touch firmware commonly lives under /opt/google and /lib/firmware
  # contains symlinks to it. Preserve those targets too.
  mkdir -p "${target_rootfs}/opt"
  if [ -d "${shim_rootfs}/opt/google" ]; then
    mkdir -p "${target_rootfs}/opt/google"
    cp -a "${shim_rootfs}/opt/google/." "${target_rootfs}/opt/google/" 2>/dev/null || true
  fi
  if [ -d "${reco_rootfs}/opt/google" ]; then
    mkdir -p "${target_rootfs}/opt/google"
    cp -a "${reco_rootfs}/opt/google/." "${target_rootfs}/opt/google/" 2>/dev/null || true
  fi

  mkdir -p "${target_rootfs}/lib/modprobe.d/"
  mkdir -p "${target_rootfs}/etc/modprobe.d/"
  cp -r "${reco_rootfs}/lib/modprobe.d/"* "${target_rootfs}/lib/modprobe.d/" 2>/dev/null || true
  cp -r "${reco_rootfs}/etc/modprobe.d/"* "${target_rootfs}/etc/modprobe.d/" 2>/dev/null || true

  # Preserve ChromeOS module-load hints. Alpine shimboot copies these into
  # /etc/modules for OpenRC's modules service, so do the same for Gentoo.
  mkdir -p "${target_rootfs}/etc/modules-load.d/"
  cp -r "${shim_rootfs}/etc/modules-load.d/"* "${target_rootfs}/etc/modules-load.d/" 2>/dev/null || true
  cp -r "${reco_rootfs}/etc/modules-load.d/"* "${target_rootfs}/etc/modules-load.d/" 2>/dev/null || true
  rm -f "${target_rootfs}/etc/modules-load.d/shimboot-hardware.conf" 2>/dev/null || true
  : > "${target_rootfs}/etc/modules"
  for mod_file in "${target_rootfs}"/etc/modules-load.d/*.conf; do
    [ -f "$mod_file" ] || continue
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$mod_file" >> "${target_rootfs}/etc/modules"
    echo >> "${target_rootfs}/etc/modules"
  done
  #decompress kernel modules if necessary - debian won't recognize these otherwise
  local compressed_files="$(find "${target_rootfs}/lib/modules" -name '*.gz')"
  if [ "$compressed_files" ]; then
    echo "$compressed_files" | xargs gunzip
  fi

  # Always regenerate module dependency metadata after merging ChromeOS modules.
  for kernel_dir in "$target_rootfs/lib/modules/"*; do
    [ -d "$kernel_dir" ] || continue
    local version="$(basename "$kernel_dir")"
    depmod -b "$target_rootfs" "$version" || true
  done
}

prune_firmware() {
  local firmware_dir="$1"
  [ -d "$firmware_dir" ] || return 0

  # Keep Chromebook essentials: Intel/Realtek/Broadcom/Qualcomm/MediaTek WiFi,
  # CPU/GPU microcode, regulatory DB, and ChromeOS touch firmware links. Delete
  # unrelated firmware families so Gentoo images do not balloon to many GB.
  find "$firmware_dir" -type f \
    ! -path "*/intel/*" \
    ! -path "*/iwlwifi/*" \
    ! -path "*/rtw88/*" \
    ! -path "*/rtw89/*" \
    ! -path "*/rtl_bt/*" \
    ! -path "*/brcm/*" \
    ! -path "*/ath10k/*" \
    ! -path "*/ath11k/*" \
    ! -path "*/mediatek/*" \
    ! -path "*/qca/*" \
    ! -path "*/amdgpu/*" \
    ! -name "regulatory.db*" \
    ! -name "*.ucode" \
    ! -iname "*elan*" \
    ! -iname "*atmel*" \
    ! -iname "*mxt*" \
    ! -iname "*touch*" \
    -delete 2>/dev/null || true
  find "$firmware_dir" -type d -empty -delete 2>/dev/null || true
}

copy_firmware() {
  local firmware_path="/tmp/chromium-firmware"
  local target_rootfs=$(realpath -m $1)

  if [ ! -e "$firmware_path" ]; then
    download_firmware $firmware_path
  fi

  cp -r --remove-destination "${firmware_path}/"* "${target_rootfs}/lib/firmware/"
  prune_firmware "${target_rootfs}/lib/firmware"
}

download_firmware() {
  local firmware_url="https://chromium.googlesource.com/chromiumos/third_party/linux-firmware"
  local firmware_path=$(realpath -m $1)

  git clone --branch master --depth=1 "${firmware_url}" $firmware_path
}

shim_path=$(realpath -m $1)
reco_path=$(realpath -m $2)
target_rootfs=$(realpath -m $3)
shim_rootfs="/tmp/shim_rootfs"
reco_rootfs="/tmp/reco_rootfs"

echo "mounting shim"
shim_loop=$(create_loop "${shim_path}")
safe_mount "${shim_loop}p3" $shim_rootfs ro

echo "mounting recovery image"
reco_loop=$(create_loop "${reco_path}")
safe_mount "${reco_loop}p3" $reco_rootfs ro

echo "copying modules to rootfs"
copy_modules $shim_rootfs $reco_rootfs $target_rootfs

echo "downloading misc firmware"
copy_firmware $target_rootfs

echo "unmounting and cleaning up"
umount $shim_rootfs
umount $reco_rootfs
losetup -d $shim_loop
losetup -d $reco_loop

echo "done"