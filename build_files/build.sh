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
### 2. INSTALL SYSTEM76 COSMIC DESKTOP, NIRI & PORTALS
### ---------------------------------------------------------------------------
# Install complete COSMIC epoch + Niri Wayland compositor + SDDM + credentials
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
    xdg-desktop-portal-cosmic \
    xdg-desktop-portal-gtk \
    gnome-keyring \
    gnome-keyring-pam \
    libsecret \
    network-manager-applet \
    niri \
    niri-settings \
    xwayland-satellite \
    fuzzel \
    waybar \
    alacritty \
    swaybg \
    swayidle \
    swaylock \
    gtklock \
    mako \
    cliphist \
    wl-clipboard \
    pavucontrol \
    brightnessctl \
    sddm \
    sddm-breeze \
    sddm-themes

### ---------------------------------------------------------------------------
### 3. FIX PAM SO SDDM AUTO-UNLOCKS GNOME-KEYRING AT LOGIN
### ---------------------------------------------------------------------------
# Ensure SDDM and any fallback greeters auto-unlock gnome-keyring at login
for pam_file in /usr/lib/pam.d/sddm /etc/pam.d/sddm /usr/lib/pam.d/cosmic-greeter /etc/pam.d/cosmic-greeter; do
    if [ -f "$pam_file" ]; then
        if ! grep -q "pam_gnome_keyring.so" "$pam_file"; then
            echo "auth       optional     pam_gnome_keyring.so" >> "$pam_file"
            echo "session    optional     pam_gnome_keyring.so auto_start" >> "$pam_file"
        fi
    fi
done

### ---------------------------------------------------------------------------
### 4. CONFIGURE SDDM DISPLAY MANAGER (THEME & INPUT DEFAULTS)
### ---------------------------------------------------------------------------
mkdir -p /usr/lib/sddm/sddm.conf.d
cat << 'EOF' > /usr/lib/sddm/sddm.conf.d/10-breeze.conf
[Theme]
Current=breeze

[General]
InputMethod=
Numlock=none
EOF

### ---------------------------------------------------------------------------
### 5. CONFIGURE XDG DESKTOP PORTALS (COSMIC + GTK FALLBACK)
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
### 6. ENABLE SDDM DISPLAY MANAGER IN SYSTEMD
### ---------------------------------------------------------------------------
systemctl disable gdm.service || true
systemctl disable cosmic-greeter.service || true
systemctl enable sddm.service

### ---------------------------------------------------------------------------
### 7. ENSURE CLEAN /VAR AND /TMP FOR OSTREE / BOOTC COMMIT
### ---------------------------------------------------------------------------
dnf5 clean all
rm -rf /var/lib/dnf /var/cache/* /tmp/*
