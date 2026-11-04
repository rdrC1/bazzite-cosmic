#!/usr/bin/env bash
set -ouex pipefail

# Copy the contents of system_files/ if present
if [ -d "/ctx/system_files" ] && [ "$(ls -A /ctx/system_files 2>/dev/null)" ]; then
    cp -avf "/ctx/system_files"/. /
fi

### ---------------------------------------------------------------------------
### 1. REMOVE GNOME SHELL, EXTENSIONS, AND GDM
### ---------------------------------------------------------------------------
# Using dnf5 to cleanly strip GNOME desktop components while protecting core 
# Bazzite gaming libraries, PipeWire, WirePlumber, and gnome-keyring.
dnf5 remove -y \
    gnome-shell \
    "gnome-shell-extension*" \
    gnome-session \
    gnome-session-wayland-session \
    gnome-classic-session \
    gnome-software \
    gnome-tour \
    gnome-tweaks \
    gnome-control-center \
    gdm \
    nautilus || true

### ---------------------------------------------------------------------------
### 2. INSTALL SYSTEM76 COSMIC DESKTOP & PORTALS
### ---------------------------------------------------------------------------
# Install COSMIC desktop environment + gnome-keyring so encrypted
# credentials and Secret Service API consumers (Bitwarden, browsers, Steam) work.
dnf5 install -y \
    @cosmic-desktop \
    cosmic-store \
    cosmic-player \
    cosmic-app-library \
    cosmic-session \
    cosmic-comp \
    cosmic-panel \
    cosmic-applets \
    cosmic-settings \
    cosmic-settings-daemon \
    cosmic-files \
    cosmic-edit \
    cosmic-term \
    cosmic-osd \
    cosmic-workspaces \
    cosmic-bg \
    cosmic-launcher \
    cosmic-notifications \
    cosmic-idle \
    cosmic-screenshot \
    cosmic-greeter \
    xdg-desktop-portal-cosmic \
    xdg-desktop-portal-gtk \
    gnome-keyring \
    gnome-keyring-pam \
    libsecret \
    network-manager-applet

### ---------------------------------------------------------------------------
### 3. FIX PAM SO COSMIC-GREETER AUTO-UNLOCKS GNOME-KEYRING AT LOGIN
### ---------------------------------------------------------------------------
# In Fedora Atomic/bootc, package defaults reside in /usr/lib/pam.d/
for pam_file in /usr/lib/pam.d/cosmic-greeter /etc/pam.d/cosmic-greeter; do
    if [ -f "$pam_file" ]; then
        if ! grep -q "pam_gnome_keyring.so" "$pam_file"; then
            echo "auth       optional     pam_gnome_keyring.so" >> "$pam_file"
            echo "session    optional     pam_gnome_keyring.so auto_start" >> "$pam_file"
        fi
    fi
done

### ---------------------------------------------------------------------------
### 4. CONFIGURE XDG DESKTOP PORTALS (PIPEWIRE SCREENCAST + GTK FALLBACK)
### ---------------------------------------------------------------------------
mkdir -p /usr/share/xdg-desktop-portal
cat << 'EOF' > /usr/share/xdg-desktop-portal/cosmic-portals.conf
[preferred]
default=cosmic;gtk;
org.freedesktop.impl.portal.ScreenCast=cosmic;
org.freedesktop.impl.portal.Screenshot=cosmic;
org.freedesktop.impl.portal.FileChooser=cosmic;gtk;
org.freedesktop.impl.portal.Secret=gnome-keyring;
EOF

### ---------------------------------------------------------------------------
### 5. ENABLE COSMIC-GREETER DISPLAY MANAGER IN SYSTEMD
### ---------------------------------------------------------------------------
systemctl disable gdm.service || true
systemctl enable cosmic-greeter.service

### ---------------------------------------------------------------------------
### 6. ENSURE CLEAN /VAR AND /TMP FOR OSTREE / BOOTC COMMIT
### ---------------------------------------------------------------------------
dnf5 clean all
rm -rf /var/lib/dnf /var/cache/* /tmp/*
