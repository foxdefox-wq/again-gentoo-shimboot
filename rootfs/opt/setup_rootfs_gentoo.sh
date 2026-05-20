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
USE="X udev elogind policykit pulseaudio gawk"

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
x11-base/xorg-server udev
media-libs/mesa X
# lightdm-gtk-greeter pulls GTK/Pango/Librsvg binpkgs that require freetype[harfbuzz,png]
media-libs/freetype harfbuzz png
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
)

graphics_packages=(
  x11-base/xorg-server
  x11-drivers/xf86-input-libinput
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

# Configure OpenRC services
print_info "Configuring OpenRC services..."

# Network
cat > /etc/conf.d/net << 'NETEOF'
config_eth0="dhcp"
dhcpcd_eth0="-t 10"
NETEOF
ln -sf /etc/init.d/net.lo /etc/run/openrc/started/net.eth0 2>/dev/null || true
rc-update add net.eth0 default 2>/dev/null || true

# Consolekit for LightDM if available
rc-update add consolekit boot 2>/dev/null || true

# Dbus
rc-update add dbus default 2>/dev/null || true

# NetworkManager
rc-update add NetworkManager default 2>/dev/null || true

# Cron
rc-update add cronie default 2>/dev/null || true

# Elogind
rc-update add elogind boot 2>/dev/null || true

# Zram
rc-update add zram-init boot 2>/dev/null || true

# Kill frecon service
cat > /etc/init.d/kill-frecon << 'FRECONEOF'
#!/sbin/runscript
description="Kill ChromeOS frecon processes"

depend() {
    need localmount
    after bootmisc
}

start() {
    ebegin "Killing ChromeOS frecon processes"
    pkill -9 frecon-lite 2>/dev/null || true
    pkill -9 frecon 2>/dev/null || true
    eend 0
}
FRECONEOF
chmod +x /etc/init.d/kill-frecon
rc-update add kill-frecon boot 2>/dev/null || true

# XDM service for LightDM
cat > /etc/init.d/xdm << 'XDMEOF'
#!/sbin/runscript
description="X Display Manager (LightDM)"

depend() {
    need localmount
    after dbus bootmisc
    use elogind
}

start() {
    ebegin "Starting LightDM"
    mkdir -p /run/lightdm
    chown root:lightdm /run/lightdm 2>/dev/null || true
    chmod 755 /run/lightdm 2>/dev/null || true
    /usr/sbin/lightdm &
    eend 0
}

stop() {
    ebegin "Stopping LightDM"
    pkill -9 lightdm 2>/dev/null || true
    pkill -9 lightdm-greeter 2>/dev/null || true
    eend 0
}
XDMEOF
chmod +x /etc/init.d/xdm
rc-update add xdm default 2>/dev/null || true

# Configure LightDM
print_info "Configuring LightDM..."
mkdir -p /etc/lightdm

cat > /etc/lightdm/lightdm.conf << LDMEOF
[Seat:*]
autologin-user=${username:-user}
user-session=xfce
allow-user-switching=true
greeter-session=lightdm-gtk-greeter
xserver-command=X -Background
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
useradd -m -G wheel,audio,video,usb,input,portage,plugdev -s /bin/bash "$username" 2>/dev/null || true

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

# Set proper shell for root
chsh -s /bin/bash root 2>/dev/null || true

# Create OpenRC runlevels if needed
mkdir -p /etc/runlevels/boot 2>/dev/null || true
mkdir -p /etc/runlevels/default 2>/dev/null || true
mkdir -p /etc/runlevels/shutdown 2>/dev/null || true

# Copy ChromeOS modules/firmware from /etc/modules-load.d to /etc/modules
if [ -d /etc/modules-load.d ]; then
  for mod_file in /etc/modules-load.d/*.conf; do
    if [ -f "$mod_file" ]; then
      cat "$mod_file" >> /etc/modules
      echo >> /etc/modules
    fi
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
