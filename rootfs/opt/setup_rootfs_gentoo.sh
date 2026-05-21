#!/bin/bash

# Setup script for Gentoo rootfs on shimboot
# This script runs inside the chroot after stage3 extraction.
# Package installation is configured to prefer Gentoo binary packages from
# the official binhost instead of compiling everything locally.

DEBUG="$1"
set -e
if [ "$DEBUG" ]; then
  set -x
fi

release_name="$2"
packages="$3"
hostname="$4"
root_passwd="$5"
username="$6"
user_passwd="$7"
enable_root="$8"
disable_base_pkgs="$9"
arch="${10}"
gentoo_binpkg_only="${11}"

# Define print functions (common.sh not available inside chroot)
print_info() {
  echo ">> $1"
}

print_error() {
  echo "ERROR: $1" >&2
}

print_title() {
  echo "=============================================="
  echo ">> $1"
  echo "=============================================="
}

# Detect if we're inside chroot
if [ ! -f /etc/passwd ]; then
  print_error "This script must be run inside the Gentoo chroot"
  exit 1
fi

# Portage needs working proc/dev bind mounts when this script is rerun manually
# with chroot. build_rootfs.sh creates these automatically, but a direct
# `chroot rootfs /opt/setup_rootfs_gentoo.sh ...` will not.
if [ ! -d /proc/self ] || [ ! -e /dev/null ]; then
  print_error "The chroot is missing required /proc or /dev mounts."
  print_error "Before rerunning this script manually, mount proc/sys/dev/run from the host:"
  print_error "  for m in proc sys dev run; do sudo mount --make-rslave --rbind /$m ROOTFS/$m; done"
  exit 1
fi

# Some tools use /dev/fd for bash process substitution. Make sure it exists
# when /dev was copied without the usual symlinks.
if [ ! -e /dev/fd ] && [ -d /proc/self/fd ]; then
  ln -s /proc/self/fd /dev/fd 2>/dev/null || true
fi
if [ ! -e /dev/stdin ] && [ -e /proc/self/fd/0 ]; then
  ln -s /proc/self/fd/0 /dev/stdin 2>/dev/null || true
fi
if [ ! -e /dev/stdout ] && [ -e /proc/self/fd/1 ]; then
  ln -s /proc/self/fd/1 /dev/stdout 2>/dev/null || true
fi
if [ ! -e /dev/stderr ] && [ -e /proc/self/fd/2 ]; then
  ln -s /proc/self/fd/2 /dev/stderr 2>/dev/null || true
fi

if [ ! -e /dev/fd/0 ]; then
  print_error "The chroot has no working /dev/fd; Portage cannot run safely."
  print_error "Exit the chroot and bind-mount /proc and /dev before rerunning setup."
  exit 1
fi

# Set up environment
export CONFIG_PROTECT="-*"
export ACCEPT_LICENSE="*"

# Set hostname
if [ ! "$hostname" ]; then
  hostname="shimboot"
fi
echo "hostname=\"${hostname}\"" > /etc/conf.d/hostname
hostname "$hostname"

# Compute values for make.conf ahead of time
NPROC="$(nproc)"

# Map shimboot arch values to Gentoo binhost paths and conservative compiler flags.
# Keeping the compiler flags/profile close to the official binhost means Portage can
# use more prebuilt packages instead of falling back to local source builds.
case "$arch" in
  amd64|x86_64)
    gentoo_arch="amd64"
    binhost_uri="https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/"
    common_flags="-O2 -pipe -march=x86-64 -mtune=generic"
    ;;
  arm64|aarch64)
    gentoo_arch="arm64"
    binhost_uri="https://distfiles.gentoo.org/releases/arm64/binpackages/23.0/arm64/"
    common_flags="-O2 -pipe"
    ;;
  *)
    print_error "Unsupported architecture for Gentoo binhost: $arch"
    exit 1
    ;;
esac

# Default to preferring binary packages. If gentoo_binpkg_only=1/true/yes is passed,
# fail instead of compiling a package that is missing from the binhost.
binpkg_mode="prefer"
case "$gentoo_binpkg_only" in
  1|true|yes|on)
    binpkg_mode="only"
    ;;
esac

# Ensure Portage directories exist before writing config.
mkdir -p /etc/portage/binrepos.conf 2>/dev/null || true
mkdir -p /etc/portage/package.accept_keywords 2>/dev/null || true
mkdir -p /etc/portage/package.use 2>/dev/null || true
mkdir -p /var/db/repos/gentoo 2>/dev/null || true
mkdir -p /var/cache/distfiles 2>/dev/null || true
mkdir -p /var/cache/binpkgs 2>/dev/null || true
mkdir -p /var/cache/binhost/gentoo 2>/dev/null || true
mkdir -p /var/tmp/portage 2>/dev/null || true

# Configure the official Gentoo binary package host explicitly. Recent stage3s may
# already contain this file, but writing it here keeps older stage3s working too.
print_info "Configuring Gentoo binary package host..."
cat > /etc/portage/binrepos.conf/gentoobinhost.conf << BINHOSTEOF
[gentoo]
priority = 9999
sync-uri = ${binhost_uri}
verify-signature = true
location = /var/cache/binhost/gentoo
BINHOSTEOF

# Configure make.conf for ChromeOS kernel compatibility and binary packages.
# Do not force ACCEPT_KEYWORDS=~amd64; the official binhost is primarily stable,
# and unstable keywords would make Portage compile many packages from source.
print_info "Configuring Portage make.conf for binary packages..."
cat > /etc/portage/make.conf << MAKEEOF
# Gentoo shimboot make.conf - tuned to use official Gentoo binary packages

COMMON_FLAGS="${common_flags}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${NPROC}"
MAKEFLAGS="-j${NPROC}"

# Keep global USE modest so Portage can match the official binhost USE sets.
# Package-specific USE below adds only the flags shimboot needs.
USE="X udev elogind policykit pulseaudio gawk -selinux"
INPUT_DEVICES="libinput evdev synaptics"

# Use official binary packages by default, with GPG signature verification.
FEATURES="getbinpkg binpkg-request-signature"
ACCEPT_LICENSE="*"

# Portage directories
PORTDIR="/var/db/repos/gentoo"
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"

# Emerge options
EMERGE_DEFAULT_OPTS="--quiet-build=y --getbinpkg --binpkg-respect-use=y --with-bdeps=n"
FETCHCOMMAND="wget -c \\\${URI} -O \\\${DISTDIR}/\\\${FILE}"
RESUMECOMMAND="wget -c \\\${URI} -O \\\${DISTDIR}/\\\${FILE}"
MAKEEOF

if [ "$binpkg_mode" = "only" ]; then
  print_info "Strict binary package mode enabled; missing binpkgs will fail the build."
  sed -i 's/EMERGE_DEFAULT_OPTS="/EMERGE_DEFAULT_OPTS="--usepkgonly /' /etc/portage/make.conf
else
  print_info "Binary packages will be preferred; Portage may compile only if no matching binpkg exists."
fi

# Explicitly set USE flags needed by this image without forcing unnecessary global
# differences that would prevent binary package matches.
cat > /etc/portage/package.use/shimboot << 'USEEOF'
app-alternatives/awk gawk
sys-auth/elogind policykit
sys-auth/polkit elogind
sys-fs/udisks elogind
x11-misc/lightdm elogind
x11-drivers/xf86-input-libinput udev
x11-base/xorg-drivers input_devices_libinput input_devices_evdev input_devices_synaptics
x11-base/xorg-server udev
media-libs/mesa X
# lightdm-gtk-greeter pulls GTK/Pango/Librsvg binpkgs that require freetype[harfbuzz,png]
media-libs/freetype harfbuzz png
# xfce4-pulseaudio-plugin pulls xfce4-panel[dbusmenu], which needs libdbusmenu[gtk3]
dev-libs/libdbusmenu gtk3
# thunar-volman requires thunar[udisks], which pulls gvfs[udisks,udev]
xfce-base/thunar udisks
gnome-base/gvfs udisks udev
# NetworkManager[wifi] requires wpa_supplicant[dbus]
net-wireless/wpa_supplicant dbus
# gvfs/libsecret/gnome-keyring chain requires legacy gcr[gtk]
app-crypt/gcr gtk
USEEOF

# Helper that installs packages through the binhost-aware Portage config.
emerge_binpkg() {
  local description="$1"
  shift

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  print_info "$description"
  if [ "$binpkg_mode" = "only" ]; then
    emerge --getbinpkg --usepkgonly --binpkg-respect-use=y --quiet-build=y "$@" 2>&1
  else
    emerge --getbinpkg --binpkg-respect-use=y --quiet-build=y "$@" 2>&1
  fi
}

# Sync portage tree. The binhost still needs repository metadata for dependency
# resolution, but package payloads will come from the binhost whenever possible.
print_info "Syncing Portage tree..."
emerge-webrsync --quiet 2>&1 || emerge --sync --quiet 2>&1

# Initialize Gentoo binhost signing keys if the trust tool is present. Do not fail
# older stage3s that do not ship getuto yet; emerge will also attempt setup when
# it first downloads signed binary packages.
if command -v getuto >/dev/null 2>&1; then
  print_info "Initializing Gentoo binhost trust keys..."
  getuto 2>&1 || true
fi

# Update world through binary packages first so the stage3 is consistent with the
# package set used for the rest of the install.
emerge_binpkg "Updating base system using binary packages..." --update --deep --changed-use @world

# Default Gentoo shimboot package set. Keep this in one install transaction so
# Portage can solve dependencies once and pull as many packages as possible from
# the official binhost.
essential_packages=(
  app-admin/sudo
  net-misc/networkmanager
  sys-process/cronie
  net-wireless/wpa_supplicant
  net-misc/dhcpcd
  app-editors/nano
  app-portage/gentoolkit
  sys-auth/elogind
  sys-auth/polkit
  sys-fs/udisks
  sys-block/zram-init
  app-shells/bash-completion
  gui-libs/display-manager-init
  x11-apps/xinit
  x11-apps/xauth
  sys-apps/kbd
)

graphics_packages=(
  x11-base/xorg-server
  x11-drivers/xf86-input-libinput
  x11-drivers/xf86-input-evdev
  x11-drivers/xf86-input-synaptics
  media-libs/mesa
)

# Intel VA/Xorg drivers are only useful on amd64 Chromebooks and are not stable
# on arm64, so keep them out of ARM builds to avoid source compiles/failures.
if [ "$gentoo_arch" = "amd64" ]; then
  graphics_packages+=(
    x11-drivers/xf86-video-intel
    media-libs/libva-intel-driver
  )
fi

desktop_packages=(
  xfce-base/xfce4-meta
  xfce-base/thunar-volman
  xfce-extra/xfce4-notifyd
  xfce-extra/xfce4-pulseaudio-plugin
  x11-misc/lightdm
  x11-misc/lightdm-gtk-greeter
)

base_packages=("${essential_packages[@]}" "${graphics_packages[@]}")
default_packages=("${base_packages[@]}" "${desktop_packages[@]}")

# If the caller supplied custom_packages, use those as the desktop/application
# package set while still installing the non-desktop shimboot base packages.
install_packages=("${default_packages[@]}")
if [ "$packages" ] && [ "$packages" != "task-xfce-desktop" ]; then
  # shellcheck disable=SC2206 # Intentional split of the custom package list.
  custom_packages=( $packages )
  install_packages=("${base_packages[@]}" "${custom_packages[@]}")
fi

emerge_binpkg "Installing shimboot package set using Gentoo binpkgs..." "${install_packages[@]}"

# Disable SELinux explicitly. Gentoo's normal OpenRC profile is not SELinux, but
# keep the image unambiguous for packages/tools that check these files.
print_info "Disabling SELinux..."
mkdir -p /etc/selinux
cat > /etc/selinux/config << 'SELINUXEOF'
SELINUX=disabled
SELINUXTYPE=targeted
SELINUXEOF

# The shimboot bootloader mounts the real rootfs before OpenRC starts. Provide a
# non-empty fstab so OpenRC localmount/checkfs do not complain, and so pseudo
# filesystems have sane definitions. bootstrap.sh updates the root device line at
# boot when it knows the selected partition path.
print_info "Writing shimboot fstab..."
mkdir -p /proc /sys /dev/pts /run /tmp
chmod 1777 /tmp
cat > /etc/fstab << 'FSTABEOF'
# shimboot-managed-fstab
# The root device is mounted by the shimboot bootloader and rewritten at boot.
/dev/root / ext4 defaults,noatime 0 1
proc /proc proc nosuid,nodev,noexec 0 0
sysfs /sys sysfs nosuid,nodev,noexec 0 0
devpts /dev/pts devpts gid=5,mode=620,nosuid,noexec 0 0
tmpfs /run tmpfs mode=0755,nosuid,nodev 0 0
tmpfs /tmp tmpfs mode=1777,nosuid,nodev 0 0
FSTABEOF

# ChromeOS kernels can make `udevadm trigger` return ENOPROTOOPT ("Protocol
# driver not attached") for a couple of sysfs devices. That should not stop the
# boot, so replace Gentoo's strict trigger service with a shimboot-tolerant one
# that logs trigger failures but always succeeds after best-effort triggering.
print_info "Installing shimboot-tolerant udev-trigger service..."
if [ -f /etc/init.d/udev-trigger ] && [ ! -f /etc/init.d/udev-trigger.gentoo ]; then
  cp -a /etc/init.d/udev-trigger /etc/init.d/udev-trigger.gentoo 2>/dev/null || true
fi
cat > /etc/init.d/udev-trigger << 'UDEVTRIGGEREOF'
#!/sbin/openrc-run

description="Trigger udev coldplug events (shimboot tolerant)"
command=/bin/true

extra_started_commands="retrigger"

depend() {
    need udev
    before modules
    keyword -lxc -systemd-nspawn -vserver
}

_start_udev_trigger() {
    mkdir -p /run
    : > /run/udev-trigger.log

    # Trigger subsystems first, then devices. Some Chromebook/ChromeOS-kernel
    # sysfs entries return "Protocol driver not attached"; log those but do not
    # fail the boot because the rest of udev coldplug still works.
    udevadm trigger --type=subsystems --action=add >>/run/udev-trigger.log 2>&1 || true
    udevadm trigger --type=devices --action=add >>/run/udev-trigger.log 2>&1 || true
    udevadm settle --timeout=15 >>/run/udev-trigger.log 2>&1 || true
    return 0
}

start() {
    ebegin "Triggering udev events"
    _start_udev_trigger
    eend 0
}

retrigger() {
    ebegin "Retriggering udev events"
    _start_udev_trigger
    eend 0
}
UDEVTRIGGEREOF
chmod +x /etc/init.d/udev-trigger

# Configure OpenRC services
print_info "Configuring OpenRC services..."

# Core OpenRC boot services. Add only if the service exists so this remains
# compatible across Gentoo stage3 snapshots.
# Match Alpine shimboot's OpenRC hardware path: devfs + mdev + hwdrivers +
# modules. Gentoo udev is kept too because desktop packages expect it, but mdev
# creates /dev nodes early like Alpine.
for svc in devfs sysfs procfs dmesg mdev hwdrivers udev udev-trigger; do
  [ -x "/etc/init.d/$svc" ] && rc-update add "$svc" sysinit 2>/dev/null || true
done
for svc in modules hwclock sysctl hostname bootmisc localmount swap; do
  [ -x "/etc/init.d/$svc" ] && rc-update add "$svc" boot 2>/dev/null || true
done
for svc in mount-ro killprocs savecache; do
  [ -x "/etc/init.d/$svc" ] && rc-update add "$svc" shutdown 2>/dev/null || true
done

# The Gentoo stage3 may include OpenRC's local service in the default runlevel.
# On shimboot it can hang at "Starting local" before tty autologin ever starts,
# and we do not use /etc/local.d for anything. Disable it explicitly.
for level in boot default nonetwork; do
  rc-update del local "$level" 2>/dev/null || true
done
rm -f /etc/runlevels/*/local 2>/dev/null || true

# NetworkManager handles networking. Do not add net.eth0: Chromebooks often do
# not have an eth0 interface, and OpenRC's net.eth0 service blocks/errors on boot
# when the interface is absent. Remove stale entries from older builds.
for level in boot default nonetwork; do
  rc-update del net.eth0 "$level" 2>/dev/null || true
done
rm -f /etc/init.d/net.eth0 2>/dev/null || true
cat > /etc/conf.d/net << 'NETEOF'
# Managed by NetworkManager on shimboot Gentoo.
NETEOF

# Consolekit for LightDM if available
[ -x /etc/init.d/consolekit ] && rc-update add consolekit boot 2>/dev/null || true

# Dbus
[ -x /etc/init.d/dbus ] && rc-update add dbus default 2>/dev/null || true

# NetworkManager
[ -x /etc/init.d/NetworkManager ] && rc-update add NetworkManager default 2>/dev/null || true

# Cron
[ -x /etc/init.d/cronie ] && rc-update add cronie default 2>/dev/null || true

# Elogind
[ -x /etc/init.d/elogind ] && rc-update add elogind boot 2>/dev/null || true

# Zram
[ -x /etc/init.d/zram-init ] && rc-update add zram-init boot 2>/dev/null || true

# Frecon must release /dev/console before Xorg/LightDM can take over the display.
mkdir -p /usr/local/bin
cat > /usr/local/bin/kill_frecon << 'KILLFRECONEOF'
#!/bin/sh
umount -l /dev/console 2>/dev/null || true
pkill -9 frecon-lite 2>/dev/null || true
pkill -9 frecon 2>/dev/null || true
# Keep /dev/console as the regular file left by the shimboot bootloader. This
# matches upstream shimboot and avoids ChromeOS-kernel console/VT weirdness.
sleep 1
exit 0
KILLFRECONEOF
chmod +x /usr/local/bin/kill_frecon

cat > /usr/local/bin/shimboot-startxfce << 'STARTXFCEEOF'
#!/bin/sh
export XDG_SESSION_TYPE=x11
export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE
exec dbus-run-session -- startxfce4
STARTXFCEEOF
chmod +x /usr/local/bin/shimboot-startxfce

# Let the fallback start Xorg as the user even when no physical Linux console
cat > /usr/local/bin/shimboot-start-user-xfce << 'USERXFCEEOF'
#!/bin/sh

# Started from the autologin user's shell. This gives elogind/PAM a real user
# session before X starts, which is what upstream Shimboot gets from
# systemd+LightDM and what root-run OpenRC services do not provide.

[ -n "$DISPLAY" ] && exec /bin/bash --login

log=/var/log/shimboot-user-xfce.log
lock=/run/shimboot-user-xfce.lock
mkdir -p /run /var/log /tmp/.X11-unix
chmod 1777 /tmp /tmp/.X11-unix 2>/dev/null || true

# Do not exit if another instance exists; exiting makes sysvinit respawn tty1
# rapidly and disables it for 5 minutes. Stay in a shell instead.
if ! mkdir "$lock" 2>/dev/null; then
    echo "shimboot-start-user-xfce: already running, opening shell" >>"$log"
    exec /bin/bash --login
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT INT TERM

echo "$(date): preparing hardware/input" >>"$log"
/usr/local/bin/shimboot-load-hwmods >>"$log" 2>&1 || true
/usr/local/bin/kill_frecon >>"$log" 2>&1 || true

# Match logind ACL behavior explicitly for OpenRC.
chgrp -R input /dev/input 2>>"$log" || true
chmod a+rw /dev/input/event* /dev/input/mouse* /dev/input/mice /dev/input/js* 2>>"$log" || true

export XDG_SESSION_TYPE=x11
export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

echo "$(date): starting XFCE via startx" >>"$log"
startx /usr/local/bin/shimboot-startxfce -- :0 vt7 -ac -nolisten tcp >>"$log" 2>&1
rc=$?
echo "$(date): startx exited with status $rc; leaving tty shell open to avoid respawn loop" >>"$log"

exec /bin/bash --login
USERXFCEEOF
chmod +x /usr/local/bin/shimboot-start-user-xfce

# login happened first.
mkdir -p /etc/X11
cat > /etc/X11/Xwrapper.config << 'XWRAPPEREOF'
allowed_users=anybody
needs_root_rights=yes
XWRAPPEREOF

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-shimboot.conf << 'XORGEOF'
Section "Device"
    Identifier "ChromeOS KMS"
    Driver "modesetting"
    Option "AccelMethod" "none"
    Option "ShadowFB" "true"
EndSection
XORGEOF

cat > /etc/X11/xorg.conf.d/40-libinput.conf << 'LIBINPUTEOF'
Section "InputClass"
    Identifier "libinput keyboard catchall"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput pointer catchall"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput touchpad catchall"
    MatchIsTouchpad "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput touchscreen catchall"
    MatchIsTouchscreen "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection
LIBINPUTEOF

cat > /etc/X11/xorg.conf.d/45-evdev-fallback.conf << 'EVDEVEOF'
Section "InputClass"
    Identifier "evdev keyboard fallback"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection

Section "InputClass"
    Identifier "evdev pointer fallback"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection
EVDEVEOF

cat > /etc/X11/xorg.conf.d/10-shimboot-serverflags.conf << 'SERVERFLAGSEOF'
Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "AutoEnableDevices" "true"
EndSection
SERVERFLAGSEOF

mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-shimboot-input.rules << 'UDEVRULESEOF'
KERNEL=="event*", SUBSYSTEM=="input", GROUP="input", MODE="0666"
KERNEL=="mouse*", SUBSYSTEM=="input", GROUP="input", MODE="0666"
KERNEL=="js*", SUBSYSTEM=="input", GROUP="input", MODE="0666"
UDEVRULESEOF

cat > /usr/local/bin/shimboot-xinitrc << 'XINITRCEOF'
#!/bin/sh
user="${SHIMBOOT_XFCE_USER:-user}"
uid="$(id -u "$user" 2>/dev/null || true)"
gid="$(id -g "$user" 2>/dev/null || true)"
if [ -z "$uid" ] || [ -z "$gid" ]; then
    echo "shimboot-xinitrc: user '$user' not found" >&2
    exit 1
fi
mkdir -p "/run/user/$uid"
chown "$uid:$gid" "/run/user/$uid"
chmod 700 "/run/user/$uid"
export DISPLAY="${DISPLAY:-:0}"
exec su - "$user" -c "DISPLAY='$DISPLAY' XDG_RUNTIME_DIR='/run/user/$uid' XDG_SESSION_TYPE=x11 DESKTOP_SESSION=xfce XDG_CURRENT_DESKTOP=XFCE dbus-run-session -- startxfce4"
XINITRCEOF
chmod +x /usr/local/bin/shimboot-xinitrc

cat > /usr/local/bin/shimboot-mdev-scan << 'MDEVSCANEOF'
#!/bin/sh

# Alpine-style device population for shimboot Gentoo.
# Alpine shimboot uses OpenRC devfs + mdev + hwdrivers + modules.  This helper
# provides the same mdev scan path while still allowing Gentoo's udev to run.

log=/run/shimboot-mdev.log
mkdir -p /run /dev
: > "$log"

find_busybox() {
    for bb in /bootloader/bin/busybox /bin/busybox /usr/bin/busybox; do
        [ -x "$bb" ] && { echo "$bb"; return 0; }
    done
    return 1
}

bb="$(find_busybox || true)"
if [ -z "$bb" ]; then
    echo "busybox not found" >> "$log"
    exit 0
fi

# Minimal mdev.conf giving X/libinput access to input nodes even without logind
# ACLs. mdev accepts missing/nonmatching rules harmlessly.
cat > /etc/mdev.conf <<'MDEVCONF'
input/event[0-9]* 0:0 0666
input/mouse[0-9]* 0:0 0666
input/mice 0:0 0666
input/js[0-9]* 0:0 0666
dri/.* 0:0 0666
MDEVCONF

# Match Alpine's mdev behavior: let mdev service future hotplug events, then
# scan current sysfs devices. Keep this best-effort so boot never blocks.
if [ -w /proc/sys/kernel/hotplug ]; then
    echo "$bb mdev" > /proc/sys/kernel/hotplug 2>>"$log" || true
fi

"$bb" mdev -s >>"$log" 2>&1 || true

# Make sure common directories/symlinks exist even with minimal mdev configs.
mkdir -p /dev/input /dev/dri /dev/snd /dev/pts /dev/shm
[ -e /dev/fd ] || ln -s /proc/self/fd /dev/fd 2>/dev/null || true
[ -e /dev/stdin ] || ln -s /proc/self/fd/0 /dev/stdin 2>/dev/null || true
[ -e /dev/stdout ] || ln -s /proc/self/fd/1 /dev/stdout 2>/dev/null || true
[ -e /dev/stderr ] || ln -s /proc/self/fd/2 /dev/stderr 2>/dev/null || true

chmod a+rw /dev/input/event* /dev/input/mouse* /dev/input/mice /dev/input/js* /dev/dri/* 2>>"$log" || true
ls -la /dev/input >>"$log" 2>&1 || true
exit 0
MDEVSCANEOF
chmod +x /usr/local/bin/shimboot-mdev-scan

cat > /etc/init.d/shimboot-mdev << 'MDEVSERVICEEOF'
#!/sbin/openrc-run

description="Populate /dev using busybox mdev for shimboot"
command="/usr/local/bin/shimboot-mdev-scan"

depend() {
    need devfs sysfs
    before udev udev-trigger modules shimboot-hwmods shimboot-xfce
}
MDEVSERVICEEOF
chmod +x /etc/init.d/shimboot-mdev
rm -f /etc/runlevels/*/shimboot-mdev 2>/dev/null || true

cat > /etc/init.d/mdev << 'MDEVCOMPATEOF'
#!/sbin/openrc-run

# Alpine-compatible mdev service for shimboot Gentoo.

description="Populate /dev with busybox mdev"
command="/usr/local/bin/shimboot-mdev-scan"

depend() {
    need devfs sysfs
    before udev udev-trigger hwdrivers modules shimboot-hwmods shimboot-xfce
}
MDEVCOMPATEOF
chmod +x /etc/init.d/mdev
rm -f /etc/runlevels/*/mdev 2>/dev/null || true
rc-update add mdev sysinit 2>/dev/null || true

cat > /usr/local/bin/shimboot-load-hwmods << 'HWMODSEOF'
#!/bin/sh

# Best-effort hardware module loader for Chromebook/ChromeOS kernels.
# ChromeOS shims often have board input devices (keyboard/touchpad/touchscreen)
# behind cros_ec, I2C-HID, and vendor touch modules that generic distro udev
# does not always autoload early enough for Xorg/libinput.

log=/run/shimboot-hwmods.log
mkdir -p /run
: > "$log"

load_mod() {
    mod="$1"
    if modprobe -q "$mod" 2>>"$log"; then
        echo "loaded $mod" >>"$log"
    else
        echo "skip $mod" >>"$log"
    fi
}

# First let depmod aliases handle all real hardware described by sysfs. This is
# the closest equivalent to ChromeOS coldplug and catches board-specific input
# devices without knowing exact module names in advance.
find /sys -name modalias -type f 2>/dev/null | while IFS= read -r alias_file; do
    alias="$(cat "$alias_file" 2>/dev/null || true)"
    [ -n "$alias" ] || continue
    modprobe -q -b "$alias" >>"$log" 2>&1 || true
done

# Buses / pinctrl / low-power-subsystem glue used by Intel Chromebooks.
for mod in \
    pinctrl_geminilake pinctrl_jasperlake pinctrl_cannonlake pinctrl_tigerlake \
    intel_lpss intel_lpss_pci intel_lpss_acpi \
    i2c_i801 i2c_designware_core i2c_designware_pci i2c_designware_platform \
    spi_pxa2xx_platform; do
    load_mod "$mod"
done

# ChromeOS Embedded Controller and Chromebook-specific input devices.
for mod in \
    chromeos_acpi chromeos_laptop chromeos_pstore chromeos_tbmc \
    cros_ec cros_ec_proto cros_ec_lpcs cros_ec_i2c cros_ec_spi cros_ec_uart \
    cros_ec_dev cros_ec_chardev cros_ec_sysfs cros_ec_debugfs \
    cros_ec_keyb cros_ec_buttons cros_ec_sensors cros_ec_sensors_core \
    cros_ec_sensorhub cros_ec_light_prox cros_usbpd_charger cros_usbpd_logger \
    cros_kbd_led_backlight \
    intel_hid intel_vbtn gpio_keys soc_button_array; do
    load_mod "$mod"
done

# HID/input/touchpad/touchscreen stack.
for mod in \
    input_core mousedev joydev evdev uinput \
    hid hid_generic usbhid hid_multitouch hid_google_hammer \
    i2c_hid i2c_hid_acpi i2c_hid_of \
    atmel_mxt_ts elants_i2c elan_i2c cyapa raydium_i2c_ts goodix \
    i8042 atkbd psmouse serio serio_raw; do
    load_mod "$mod"
done

# Load every module in the ChromeOS tree whose filename looks input/HID/I2C/EC
# related. Some ChromeOS module names vary from upstream, so a static list is
# not enough.
for depfile in /lib/modules/"$(uname -r)"/modules.dep /lib/modules/"$(uname -r)"/modules.dep.bin; do
    [ -f "$depfile" ] || continue
    sed 's/:.*//' "$depfile" 2>/dev/null | while IFS= read -r path; do
        base="${path##*/}"
        mod="${base%%.ko*}"
        case "$mod" in
            *cros*|*chrome*|*ec*|*hid*|*i2c*|*elan*|*elants*|*atmel*|*mxt*|*cyapa*|*touch*|*kbd*|*keyb*|*input*|*serio*|*atkbd*|*psmouse*|*gpio*|*button*)
                load_mod "$mod"
                ;;
        esac
    done
    break
done

# Load any copied ChromeOS module-load hints too, but keep this non-fatal.
for conf in /etc/modules-load.d/*.conf; do
    [ -f "$conf" ] || continue
    while IFS= read -r mod _args; do
        case "$mod" in ''|'#'*) continue ;; esac
        load_mod "$mod"
    done < "$conf"
done

# Some ELAN touchpads bind to elan_i2c but only work through i2c_hid_acpi on
# ChromeOS kernels. If those driver directories exist, try the harmless rebind.
for dev in /sys/bus/i2c/drivers/elan_i2c/i2c-* /sys/bus/i2c/drivers/elants_i2c/i2c-*; do
    [ -e "$dev" ] || continue
    name="${dev##*/}"
    driver="$(basename "$(dirname "$dev")")"
    echo "$name" > "/sys/bus/i2c/drivers/$driver/unbind" 2>>"$log" || true
    echo "$name" > /sys/bus/i2c/drivers/i2c_hid_acpi/bind 2>>"$log" || true
done

# Populate /dev Alpine-style after modules are loaded, then also ask udev if it
# is running. This covers both mdev-created nodes and udev-managed permissions.
/usr/local/bin/shimboot-mdev-scan >>"$log" 2>&1 || true
udevadm trigger --subsystem-match=input --action=add >>"$log" 2>&1 || true
udevadm trigger --subsystem-match=hid --action=add >>"$log" 2>&1 || true
udevadm trigger --subsystem-match=i2c --action=add >>"$log" 2>&1 || true
udevadm settle --timeout=10 >>"$log" 2>&1 || true
/usr/local/bin/shimboot-mdev-scan >>"$log" 2>&1 || true

# Be deliberately permissive: shimboot's Debian path relies on systemd/logind
# ACLs. On OpenRC, make input nodes readable by X no matter whether X is root,
# rootless, libinput, or evdev.
mkdir -p /dev/input
chgrp -R input /dev/input 2>>"$log" || true
chmod a+rw /dev/input/event* /dev/input/mouse* /dev/input/js* 2>>"$log" || true

ls -la /dev/input >>"$log" 2>&1 || true
cat /proc/bus/input/devices >>"$log" 2>&1 || true

exit 0
HWMODSEOF
chmod +x /usr/local/bin/shimboot-load-hwmods

cat > /etc/init.d/shimboot-hwmods << 'HWMODSSERVICEEOF'
#!/sbin/openrc-run

description="Load Chromebook hardware/input modules for shimboot"
command="/usr/local/bin/shimboot-load-hwmods"

depend() {
    need sysfs mdev
    after mdev hwdrivers modules udev-trigger
    before display-manager xdm shimboot-xfce
}
HWMODSSERVICEEOF
chmod +x /etc/init.d/shimboot-hwmods
rm -f /etc/runlevels/*/shimboot-hwmods 2>/dev/null || true

# Kill frecon helper service. It runs in the default runlevel immediately before
# the display manager, not in boot, so the visible console is released only when
# X/LightDM is about to start.
cat > /etc/init.d/kill-frecon << 'FRECONEOF'
#!/sbin/openrc-run
description="Release ChromeOS frecon console for Xorg"
command="/usr/local/bin/kill_frecon"

depend() {
    need localmount
    after bootmisc modules
    before display-manager xdm
}
FRECONEOF
chmod +x /etc/init.d/kill-frecon
rm -f /etc/runlevels/*/kill-frecon 2>/dev/null || true

# XDM service for LightDM. Gentoo installs lightdm as /usr/bin/lightdm; keep a
# /usr/sbin fallback for compatibility with other layouts.
cat > /etc/init.d/xdm << 'XDMEOF'
#!/sbin/openrc-run
description="X Display Manager (LightDM)"
pidfile="/run/lightdm.pid"
command_background="yes"

get_lightdm_command() {
    if [ -x /usr/bin/lightdm ]; then
        echo /usr/bin/lightdm
    elif [ -x /usr/sbin/lightdm ]; then
        echo /usr/sbin/lightdm
    else
        return 1
    fi
}

depend() {
    need localmount dbus
    after bootmisc modules kill-frecon elogind
    use elogind
}

start_pre() {
    /usr/local/bin/kill_frecon 2>/dev/null || true
    mkdir -p /run/lightdm /var/log/lightdm
    chown root:lightdm /run/lightdm /var/log/lightdm 2>/dev/null || true
    chmod 755 /run/lightdm /var/log/lightdm 2>/dev/null || true
    command="$(get_lightdm_command)" || return 1
}

start() {
    ebegin "Starting LightDM"
    start_pre || return 1
    start-stop-daemon --start --quiet --background --make-pidfile \
        --pidfile "$pidfile" --exec "$command"
    eend $?
}

stop() {
    ebegin "Stopping LightDM"
    start-stop-daemon --stop --quiet --retry TERM/5/KILL/5 \
        --pidfile "$pidfile" 2>/dev/null || true
    pkill -9 lightdm 2>/dev/null || true
    pkill -9 lightdm-gtk-greeter 2>/dev/null || true
    eend 0
}
XDMEOF
chmod +x /etc/init.d/xdm

# Start XFCE directly. LightDM remains installed/configured, but direct xinit is
# the default because it is more reliable in the ChromeOS shimboot frecon/VT
# environment. This still uses binpkg-installed XFCE; no manual emerge here.
cat > /etc/init.d/shimboot-xfce << 'SHIMBOOTXFCEEOF'
#!/sbin/openrc-run

description="Start XFCE directly for shimboot"
pidfile="/run/shimboot-xfce.pid"
_log="/var/log/shimboot-xfce.log"
_user="${SHIMBOOT_XFCE_USER:-user}"

depend() {
    need localmount dbus
    after bootmisc modules elogind
    use elogind
}

start() {
    ebegin "Starting shimboot XFCE"

    mkdir -p /run /var/log /tmp/.X11-unix
    chmod 1777 /tmp /tmp/.X11-unix 2>/dev/null || true
    rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true

    # Match upstream shimboot/NixOS behavior: release frecon immediately before
    # starting X, not earlier in boot.
    /usr/local/bin/kill_frecon >> "$_log" 2>&1 || true

    # Match systemd/logind ACL behavior from upstream shimboot by ensuring X can
    # read input devices under OpenRC.
    mkdir -p /dev/input
    chgrp -R input /dev/input 2>>"$_log" || true
    chmod a+rw /dev/input/event* /dev/input/mouse* /dev/input/js* 2>>"$_log" || true

    if [ ! -x /usr/bin/xinit ]; then
        echo "xinit is missing" >> "$_log"
        eend 1
        return 1
    fi

    (
        export SHIMBOOT_XFCE_USER="$_user"
        if [ -x /usr/bin/openvt ]; then
            exec /usr/bin/openvt -c 7 -f -- \
                /usr/bin/xinit /usr/local/bin/shimboot-xinitrc -- :0 vt7 -ac -nolisten tcp >> "$_log" 2>&1
        else
            exec /usr/bin/xinit /usr/local/bin/shimboot-xinitrc -- :0 vt7 -ac -nolisten tcp >> "$_log" 2>&1
        fi
    ) &
    echo $! > "$pidfile"

    eend 0
}

stop() {
    ebegin "Stopping shimboot XFCE"
    if [ -f "$pidfile" ]; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    fi
    pkill -9 xfce4-session 2>/dev/null || true
    pkill -9 startxfce4 2>/dev/null || true
    pkill -9 Xorg 2>/dev/null || true
    pkill -9 X 2>/dev/null || true
    eend 0
}
SHIMBOOTXFCEEOF
chmod +x /etc/init.d/shimboot-xfce

# Avoid display-manager/xdm races and blank greeter failures. They are left
# installed for manual debugging, but shimboot-xfce is the default graphical path.
rm -f /etc/runlevels/*/display-manager /etc/runlevels/*/xdm /etc/runlevels/*/kill-frecon /etc/runlevels/*/shimboot-xfce-fallback /etc/runlevels/*/shimboot-xfce 2>/dev/null || true
rc-update add devfs sysinit 2>/dev/null || true
rc-update add mdev sysinit 2>/dev/null || true
[ -x /etc/init.d/hwdrivers ] && rc-update add hwdrivers sysinit 2>/dev/null || true
rc-update del shimboot-hwmods default 2>/dev/null || true
rm -f /etc/runlevels/*/shimboot-hwmods 2>/dev/null || true
rc-update del shimboot-xfce default 2>/dev/null || true
for level in boot default nonetwork; do
  rc-update del local "$level" 2>/dev/null || true
done
rm -f /etc/runlevels/*/local 2>/dev/null || true

# Configure LightDM
print_info "Configuring LightDM..."
mkdir -p /etc/lightdm /etc/conf.d

# These are for compatibility with Gentoo's display-manager-init/xdm tooling if
# present, although shimboot starts LightDM through /etc/init.d/xdm directly.
echo 'DISPLAYMANAGER="lightdm"' > /etc/conf.d/xdm
echo 'DISPLAYMANAGER="lightdm"' > /etc/conf.d/display-manager

cat > /etc/lightdm/lightdm.conf << LDMEOF
[LightDM]
log-directory=/var/log/lightdm
run-directory=/run/lightdm

[Seat:*]
autologin-user=${username:-user}
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
greeter-session=lightdm-gtk-greeter
allow-user-switching=true
LDMEOF

mkdir -p /etc/lightdm/lightdm-gtk-greeter.conf.d
cat > /etc/lightdm/lightdm-gtk-greeter.conf.d/50-shimboot.conf << 'GREETEREOF'
[greeter]
theme-name=Greybird
icon-theme-name=Adwaita
background-color=#2e3436
GREETEREOF

# Configure zram
print_info "Configuring zram..."
cat > /etc/conf.d/zram-init << 'ZRAMEOF'
ALGO="lzo"
PERCENT="50"
ZRAMEOF

# Create user
if [ ! "$username" ]; then
  username="user"
fi

print_info "Creating user: $username"
groupadd -r autologin 2>/dev/null || true
useradd -m -G wheel,audio,video,usb,input,portage,plugdev,autologin -s /bin/bash "$username" 2>/dev/null || true
usermod -a -G wheel,audio,video,usb,input,portage,plugdev,autologin "$username" 2>/dev/null || true

# Configure sudo idempotently
if ! grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers 2>/dev/null; then
  echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi
if ! grep -q "^$username ALL=(ALL:ALL) NOPASSWD: ALL" /etc/sudoers 2>/dev/null; then
  echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
fi

# Set passwords
set_password() {
  local user="$1"
  local password="$2"
  if [ ! "$password" ]; then
    while ! passwd "$user"; do
      echo "Failed to set password for $user, please try again."
    done
  else
    yes "$password" | passwd "$user" 2>/dev/null || true
  fi
}

if [ "$enable_root" ]; then
  set_password root "$root_passwd"
else
  # Allow wheel group sudo without password for user
  if ! grep -q '^%wheel ALL=(ALL:ALL) NOPASSWD: ALL' /etc/sudoers 2>/dev/null; then
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
  fi
fi

set_password "$username" "$user_passwd"

# Add bashrc with shimboot greeter
if [ -f "/home/$username/.bashrc" ]; then
  if ! grep -q "shimboot_greeter" "/home/$username/.bashrc"; then
    echo '/usr/local/bin/shimboot_greeter 2>/dev/null || true' >> "/home/$username/.bashrc"
  fi
fi

# Autologin on tty1 and start XFCE from the user's login shell. This mirrors the
# important upstream behavior: a real user session exists before X opens input.
cat > "/home/$username/.bash_profile" << 'BASHPROFILEEOF'
# shimboot autostart XFCE on first tty login
if [ -z "$DISPLAY" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
  exec /usr/local/bin/shimboot-start-user-xfce
fi
BASHPROFILEEOF
chown "$username:$username" "/home/$username/.bash_profile" 2>/dev/null || true

if [ -f /etc/inittab ]; then
  if grep -q '^c1:' /etc/inittab; then
    sed -i "s#^c1:.*#c1:12345:once:/sbin/agetty --autologin $username --noclear 38400 tty1 linux#" /etc/inittab
  else
    echo "c1:12345:once:/sbin/agetty --autologin $username --noclear 38400 tty1 linux" >> /etc/inittab
  fi
fi

# Set proper shell for root
chsh -s /bin/bash root 2>/dev/null || true

# Create OpenRC runlevels if needed
mkdir -p /etc/runlevels/boot 2>/dev/null || true
mkdir -p /etc/runlevels/default 2>/dev/null || true
mkdir -p /etc/runlevels/shutdown 2>/dev/null || true

# OpenRC's modules service reads /etc/modules, not /etc/modules-load.d.
# Match Alpine shimboot's approach: copy module-load hints into /etc/modules.
# patch_rootfs.sh may append more ChromeOS board-specific hints after setup.
: > /etc/modules
if [ -d /etc/modules-load.d ]; then
  for mod_file in /etc/modules-load.d/*.conf; do
    [ -f "$mod_file" ] || continue
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$mod_file" >> /etc/modules
    echo >> /etc/modules
  done
fi

# Clean up. Avoid depclean in strict binpkg mode: if a dependency has no current
# binpkg, a cleanup pass can turn a successful binary install into a source-build
# or failure. The final image build will squash/compress caches anyway.
if [ "$binpkg_mode" != "only" ]; then
  print_info "Cleaning unused Portage packages..."
  emerge --depclean --quiet=y 2>/dev/null || true
fi

print_info ""
print_info "=============================================="
print_info "Gentoo shimboot setup complete!"
print_info ""
print_info "Default credentials:"
print_info "  Username: $username"
print_info "  Password: $user_passwd"
print_info ""
print_info "Desktop: XFCE with LightDM"
print_info "Init: OpenRC (not systemd)"
print_info "Packages: Gentoo binhost mode = $binpkg_mode"
print_info "=============================================="
print_info ""
print_info "Note: patch_rootfs.sh will copy ChromeOS modules and firmware."
