#!/usr/bin/env bash
set -ouex pipefail

# Copy the contents of system_files/ if present
if [ -d "/ctx/system_files" ] && [ "$(ls -A /ctx/system_files 2>/dev/null)" ]; then
    cp -avf "/ctx/system_files"/. /
fi

### ---------------------------------------------------------------------------
### 1. INSTALL NIRI, XWAYLAND SATELLITE & COMPANION SUITE
### ---------------------------------------------------------------------------
# Base image is bazzite-gnome:stable.
# All GNOME apps (Nautilus, Loupe, Ptyxis, Settings, Keyring), Adwaita theme,
# Cantarell/Inter fonts, GDM, PipeWire and Bazzite gaming tools are already built-in.
# Here we add Niri and its companion ecosystem:
dnf5 install -y \
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
    mate-polkit

### ---------------------------------------------------------------------------
### 2. ENSURE GDM DISPLAY MANAGER IS ENABLED
### ---------------------------------------------------------------------------
systemctl enable gdm.service

### ---------------------------------------------------------------------------
### 3. CLEAN UP PACKAGE CACHES FOR BOOTC / OSTREE
### ---------------------------------------------------------------------------
dnf5 clean all
rm -rf /var/lib/dnf /var/cache/* /tmp/*
