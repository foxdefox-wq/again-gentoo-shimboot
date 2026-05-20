#!/bin/bash

# Setup script for Gentoo rootfs on shimboot
# This script runs inside the chroot after stage3 extraction

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

# Detect if we're inside chroot
if [ ! -f /etc/portage/make.conf ]; then
  echo "Error: This script must be run inside the Gentoo chroot"
  exit 1
fi

export CONFIG_PROTECT="-*"
export USE="-*"

# Function to unmount on exit
cleanup_chroot() {
    umount -l /proc 2>/dev/null || true
    umount -l /sys 2>/dev/null || true
    umount -l /dev/pts 2>/dev/null || true
    umount -l /dev 2>/dev/null || true
}

trap cleanup_chroot EXIT

# Set hostname
if [ ! "$hostname" ]; then
  hostname="shimboot"
fi
echo "hostname=\"${hostname}\"" > /etc/conf.d/hostname
hostname "$hostname"

# Configure make.conf for ChromeOS kernel compatibility
print_info "Configuring Portage make.conf..."
cat > /etc/portage/make.conf << 'MAKEEOF'
# Gentoo shimboot make.conf - optimized for ChromeOS kernel compatibility

CFLAGS="-O2 -pipe -march=native"
CXXFLAGS="${CFLAGS}"
MAKEOPTS="-j$(nproc)"

# USE flags for XFCE desktop with LightDM
USE="X xfce thunar udev policykit elogind udisksconsole networkmanager pulseaudio"

# Accept all licenses for binary packages
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"

# Portage directories
PORTDIR="/var/db/repos/gentoo"
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"

# Emerge options
EMERGE_DEFAULT_OPTS="--quiet-build=y --verbose-build=n"

# Enable parallel make
MAKEOPTS="-j$(nproc) -l$(nproc)"
MAKEFLAGS="-j$(nproc)"
MAKE_CONF_JOBS="-j$(nproc)"
PORTAGE_NICENESS="10"
PORTAGE_JOBS="4"
FETCHCOMMAND="wget -c \${URI} -O \${DISTDIR}/\${FILE}"
RESUMECOMMAND="wget -c \${URI} -O \${DISTDIR}/\${FILE}"
MAKE Conf in Portage
EOF

# Ensure portage directories exist
mkdir -p /etc/portage/package.accept_keywords
mkdir -p /etc/portage/package.use
mkdir -p /var/db/repos/gentoo
mkdir -p /var/cache/distfiles
mkdir -p /var/tmp/portage

# Sync portage tree
print_info "Syncing Portage tree..."
emerge-webrsync --quiet || emerge --sync --quiet

# Update world
print_info "Updating base system..."
emerge --quiet-build=y @world

# Install essential packages
print_info "Installing base packages..."
emerge --quiet-build=y \
  sudo \
  networkmanager \
  cronie \
  wpa_supplicant \
  dhcpcd \
  nano \
  gentoolkit \
  elogind \
  polkit \
  udisks \
  zram-init \
  bash-completion

# Install Xorg and graphics drivers
print_info "Installing Xorg and graphics drivers..."
emerge --quiet-build=y \
  xorg-server \
  xf86-input-libinput \
  xf86-video-intel \
  mesa \
  glamor-egl \
  libva-intel-driver

# Install XFCE desktop with LightDM
print_info "Installing XFCE desktop with LightDM..."
emerge --quiet-build=y \
  xfce-base/xfce4-meta \
  xfce-extra/thunar-volman \
  xfce-extra/xfce4-notifyd \
  xfce-extra/xfce4-pulseaudio-plugin \
  lightdm \
  lightdm-gtk-greeter

# Configure OpenRC services
print_info "Configuring OpenRC services..."

# Network
cat > /etc/conf.d/net << 'NETEOF'
config_eth0="dhcp"
dhcpcd_eth0="-t 10"
NETEOF
ln -sf /etc/init.d/net.lo /etc/run/openrc/started/net.eth0 2>/dev/null || true
rc-update add net.eth0 default 2>/dev/null || true

# Consolekit for LightDM
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
}

start() {
    ebegin "Starting LightDM"
    mkdir -p /run/lightdm
    chown root:lightdm /run/lightdm 2>/dev/null || true
    touch /run/lightdm/lightdm.pid
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

cat > /etc/lightdm/lightdm.conf << 'LDMEOF'
[Seat:*]
autologin-user=user
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
useradd -m -G wheel,audio,video,usb,input,portage,plugdev -s /bin/bash "$username"

# Configure sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Set passwords
set_password() {
  local user="$1"
  local password="$2"
  if [ ! "$password" ]; then
    while ! passwd $user; do
      echo "Failed to set password for $user, please try again."
    done
  else
    yes "$password" | passwd $user
  fi
}

if [ "$enable_root" ]; then 
  set_password root "$root_passwd"
else
  # Allow wheel group sudo without password for user
  echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
fi

set_password "$username" "$user_passwd"

# Add bashrc with shimboot greeter
if [ -f "/home/$username/.bashrc" ]; then
  if ! grep -q "shimboot_greeter" "/home/$username/.bashrc"; then
    echo '/usr/local/bin/shimboot_greeter 2>/dev/null || true' >> "/home/$username/.bashrc"
  fi
fi

# Set proper shell for root
chsh -s /bin/bash root

# Create OpenRC runlevels if needed
mkdir -p /etc/runlevels/boot
mkdir -p /etc/runlevels/default
mkdir -p /etc/runlevels/shutdown

# Copy ChromeOS modules/firmware from /etc/modules-load.d to /etc/modules
if [ -d /etc/modules-load.d ]; then
  for mod_file in /etc/modules-load.d/*.conf; do
    if [ -f "$mod_file" ]; then
      cat "$mod_file" >> /etc/modules
      echo >> /etc/modules
    fi
  done
fi

# Clean up
print_info "Cleaning portage cache..."
emerge --depclean --quiet=y 2>/dev/null || true

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
print_info "=============================================="
print_info ""
print_info "Note: patch_rootfs.sh will copy ChromeOS modules and firmware."