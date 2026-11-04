# ARCHITECTURAL SPECIFICATION & AUTONOMOUS AGENT RUNBOOK: bazzite-cosmic Atomic Migration

## 0. Agent Directives & Execution Constraints

```yaml
agent_execution_policy:
  target_os: "Bazzite Linux (Fedora Atomic / bootc / ostree base)"
  filesystem_layout:
    root: "Read-only immutable ostree deployment (/usr)"
    etc: "Mutable 3-way merge configuration (/etc)"
    var_home: "Mutable Btrfs subvolume (/var/home -> /home)"
    encryption: "LUKS2 physical volume"
  strict_prohibitions:
    - "NEVER run rm -rf on ~/.config, ~/.local, or /var/home."
    - "NEVER commit cosign.key (private key) to git tracking."
    - "NEVER use interactive CLI prompts without non-interactive flags (--yes, -f, COSIGN_PASSWORD='')."
    - "NEVER remove gdm or gnome-keyring-pam unless explicitly rewriting /etc/pam.d/cosmic-greeter."
  privilege_escalation:
    - "Do not execute GitHub repo creation, git operations, or cosign key generation as root."
    - "Only use sudo for btrfs, ostree, rpm-ostree, and /etc/containers/ policy registration."
  error_handling:
    - "Verify exit code 0 after every Phase before proceeding."
    - "If dnf5/rpm-ostree package resolution fails inside Containerfile, inspect dependency locks before forcing removals."
```

---

## Phase 1: Local Host Pre-Flight Inspection & Lifeboat Creation

Before touching GitHub or building container images, lock down the current host state so any failure can be reversed in less than 10 seconds at the GRUB menu or via Btrfs subvolume restore.

### 1.1 Verify Current OSTree, Btrfs, and Encryption State
Execute the following non-destructive inspection commands:

```bash
# 1. Inspect current active deployment, layered packages, and base image digest
rpm-ostree status --verbose

# 2. Verify /var/home is mounted on a Btrfs filesystem and check free space
df -Th /var/home
sudo btrfs filesystem df /var/home
sudo btrfs subvolume list /var/home

# 3. Check LUKS / crypttab configuration to verify if TPM2 or passphrase unlock is active
cat /etc/crypttab
```

**Expected Verification Criteria:**
- `rpm-ostree status` must show an active (`●`) deployment based on `bazzite-gnome`.
- `/var/home` must report `btrfs` as its fstype.

### 1.2 Pin the Active Working Deployment in OSTree / GRUB
Pinning deployment 0 guarantees that `rpm-ostree cleanup` and future updates will never garbage-collect your working GNOME environment.

```bash
sudo ostree admin pin 0
```

**Verification:**
```bash
rpm-ostree status | grep -A 5 "●" | grep "Pinned: yes"
```
*(Must exit 0 and output `Pinned: yes`)*.

### 1.3 Create an Atomic Read-Only Btrfs Snapshot of `/var/home`
Create an instant copy-on-write snapshot of `/var/home`. Because Btrfs snapshots share extents, this consumes 0 MB of extra disk space initially and completes in milliseconds.

```bash
export SNAPSHOT_NAME=".snapshot-pre-cosmic-$(date +%Y%m%d-%H%M%S)"
sudo btrfs subvolume snapshot -r /var/home "/var/home/${SNAPSHOT_NAME}"
```

**Verification:**
```bash
sudo btrfs subvolume show "/var/home/${SNAPSHOT_NAME}"
```
*(Must output snapshot UUID, creation time, and `Flags: readonly`)*.

### 1.4 Record Layered Packages & Reset Local Overrides
If packages are currently layered locally via `rpm-ostree install`, save that list so the AI agent can bake them directly into the GitHub Containerfile instead of layering them locally.

```bash
rpm-ostree status --json | jq -r '.deployments[0]."requested-packages"[]' > ~/layered-packages-backup.txt
cat ~/layered-packages-backup.txt
```
*(Note: Do not run `rpm-ostree reset` until Phase 5 when the cloud image is built and ready to pull)*.

---

## Phase 2: Automated GitHub Repository, Cosign Cryptography & GHCR Setup

This phase can be executed 100% from the terminal by an AI agent using the `gh` (GitHub CLI), `git`, and `cosign` binaries.

### 2.1 Verify CLI Tooling Availability
Check if `gh`, `cosign`, and `jq` exist on the host or inside a Distrobox/Brew environment:

```bash
which gh cosign git jq
gh auth status
```
If `cosign` or `gh` is missing on the host, install via `brew install gh cosign jq` (Bazzite includes Homebrew out of the box at `/home/linuxbrew/.linuxbrew/bin/brew`).

### 2.2 Clone the Official Universal Blue Image Template via `gh`
Create a public repository from `ublue-os/image-template`. Using a Public repository is strongly recommended because GitHub provides unlimited free GitHub Actions CI build minutes and free public container hosting on ghcr.io.

```bash
export GITHUB_USER=$(gh api user -q ".login" | tr '[:upper:]' '[:lower:]')
export REPO_NAME="bazzite-cosmic"
export WORK_DIR="$HOME/Projects/${REPO_NAME}"

mkdir -p "$HOME/Projects"
cd "$HOME/Projects"

# Create the repository on GitHub from ublue-os/image-template and clone it locally
gh repo create "${REPO_NAME}" --public --template="ublue-os/image-template" --clone
cd "${WORK_DIR}"

# Wait 3 seconds for GitHub template hydration if the initial clone is empty, then pull
sleep 3
git pull origin main
```

### 2.3 Non-Interactive Cosign Keypair Generation & Secret Upload
Universal Blue and bootc/rpm-ostree use Sigstore cosign to cryptographically sign container digests pushed to ghcr.io. If an agent runs `cosign generate-key-pair` interactively, it will hang waiting for a password prompt. Pass `COSIGN_PASSWORD=""` to generate an unencrypted private key suitable for GitHub Actions `SIGNING_SECRET`.

```bash
cd "${WORK_DIR}"

# Remove the placeholder template public key
rm -f cosign.pub cosign.key

# Generate a fresh keypair non-interactively
COSIGN_PASSWORD="" cosign generate-key-pair

# Verify both files exist and are non-empty
test -s cosign.key && test -s cosign.pub
```

Now upload `cosign.key` directly into the repository's GitHub Actions secrets as `SIGNING_SECRET` and immediately shred the local private key so it can never be committed to git:

```bash
# Upload private key to GitHub Actions Secrets
gh secret set SIGNING_SECRET < cosign.key --repo "${GITHUB_USER}/${REPO_NAME}"

# Verify the secret is registered on GitHub
gh secret list --repo "${GITHUB_USER}/${REPO_NAME}" | grep SIGNING_SECRET

# Securely delete the private key from local disk
shred -u cosign.key
```

### 2.4 Configure GitHub Actions Workflow Permissions
Ensure GitHub Actions has write permissions for packages (to push to ghcr.io) and id-token (for OIDC signing).

```bash
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${GITHUB_USER}/${REPO_NAME}/actions/permissions/workflow" \
  -f default_workflow_permissions='write' \
  -F can_approve_pull_request_reviews=true
```

---

## Phase 3: Image Engineering (Containerfile, build.sh, and CI Workflow)

### 3.1 Why Bazzite Uses dnf5 in Modern Container Builds
Modern Bazzite images (`:stable` on Fedora 43/44+) are standard OCI bootable containers (bootc compatible). Inside the container build environment:
- `dnf5` is the native package manager and is significantly faster and cleaner at resolving dependency swaps than legacy `rpm-ostree override remove` wrappers.
- **Critical Dependency Rule (`gnome-shell` vs `gdm`):** In Fedora packaging, `gdm` has a hard dependency on `gnome-shell` because GDM uses a stripped-down `gnome-shell --mode=gdm` session to draw the login screen.
- **Architecture Selected:** Architecture A (Pure COSMIC — Zero GNOME Shell on Disk, with the PAM Keyring Auto-Unlock Fix). It eliminates GNOME Shell and its dependencies while solving the keyring unlock issue at build time.

### 3.2 Write the Production Containerfile
Overwrite `${WORK_DIR}/Containerfile`:

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE_URL="ghcr.io/ublue-os/bazzite-gnome"
ARG BASE_IMAGE_TAG="stable"

FROM ${BASE_IMAGE_URL}:${BASE_IMAGE_TAG}

# Copy build scripts and system configuration overlays
COPY build_files/build.sh /tmp/build.sh

# Run build script, verify bootc/ostree lint compliance, and commit layer
RUN --mount=type=cache,dst=/var/cache/dnf \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    chmod +x /tmp/build.sh && \
    /tmp/build.sh && \
    rm -rf /tmp/* /var/tmp/* && \
    ostree container commit
```

### 3.3 Write the Production `build_files/build.sh` Script
Create directory `${WORK_DIR}/build_files` and write `build_files/build.sh`:

```bash
#!/usr/bin/env bash
set -ouex pipefail

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
# Install the complete COSMIC epoch plus gnome-keyring + seahorse so encrypted
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
### 6. ENSURE CLEAN /VAR AND /TMP FOR OSTREE COMMIT
### ---------------------------------------------------------------------------
dnf5 clean all
rm -rf /var/lib/dnf /var/cache/* /tmp/*
```

Make the script executable:
```bash
chmod +x "${WORK_DIR}/build_files/build.sh"
```

### 3.4 `.github/workflows/build.yml` Configuration

```yaml
name: Build Custom Bazzite-COSMIC Image

on:
  schedule:
    - cron: '0 6 * * *' # Daily rebuild at 06:00 UTC to pull latest Bazzite security/kernel updates
  push:
    branches: [ main ]
    paths:
      - 'Containerfile'
      - 'build_files/**'
      - 'cosign.pub'
      - '.github/workflows/**'
  workflow_dispatch:

env:
  IMAGE_REGISTRY: ghcr.io/${{ github.repository_owner }}
  IMAGE_NAME: bazzite-cosmic
  DEFAULT_TAG: latest

permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  build_push:
    runs-on: ubuntu-24.04
    steps:
      - name: Maximize Build Space (Required for large Bazzite images on GitHub Runners)
        uses: easimon/maximize-build-space@master
        with:
          root-reserve-mb: 2048
          temp-reserve-mb: 1024
          remove-dotnet: 'true'
          remove-android: 'true'
          remove-haskell: 'true'
          remove-codeql: 'true'

      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Build Image with Buildah
        id: build_image
        uses: redhat-actions/buildah-build@v2
        with:
          image: ${{ env.IMAGE_NAME }}
          tags: ${{ env.DEFAULT_TAG }} ${{ github.sha }}
          containerfiles: ./Containerfile
          oci: true

      - name: Login to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push Image to GHCR
        id: push_image
        uses: redhat-actions/push-to-registry@v2
        with:
          image: ${{ steps.build_image.outputs.image }}
          tags: ${{ steps.build_image.outputs.tags }}
          registry: ${{ env.IMAGE_REGISTRY }}

      - name: Install Cosign
        uses: sigstore/cosign-installer@v3

      - name: Sign Container Image with Cosign
        env:
          COSIGN_PASSWORD: ""
          COSIGN_PRIVATE_KEY: ${{ secrets.SIGNING_SECRET }}
        run: |
          cosign sign -y --key env://COSIGN_PRIVATE_KEY "${{ env.IMAGE_REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.push_image.outputs.digest }}"
```

### 3.5 Commit, Push, and Monitor the Build via `gh` CLI

```bash
cd "${WORK_DIR}"
git add Containerfile build_files/build.sh cosign.pub .github/workflows/build.yml
git commit -m "feat: configure Bazzite-to-COSMIC atomic build with PAM keyring fix"
git push origin main

# Wait 5 seconds for workflow registration, then watch the live run
sleep 5
RUN_ID=$(gh run list --workflow=build.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "${RUN_ID}" --exit-status
```

**Verification:**
```bash
cosign verify --key "${WORK_DIR}/cosign.pub" "ghcr.io/${GITHUB_USER}/${REPO_NAME}:latest"
```

---

## Phase 4: Local Cryptographic Trust Registration (`policy.json`)

To rebase directly using `ostree-image-signed:docker://...`, register your `cosign.pub` key locally inside `/etc/pki/containers/` and `/etc/containers/policy.json`.

### 4.1 Install Your Public Key into `/etc/pki/containers/`
```bash
sudo mkdir -p /etc/pki/containers
sudo cp "${WORK_DIR}/cosign.pub" "/etc/pki/containers/${GITHUB_USER}-${REPO_NAME}.pub"
sudo chmod 644 "/etc/pki/containers/${GITHUB_USER}-${REPO_NAME}.pub"
```

### 4.2 Register Your GHCR Namespace in `/etc/containers/policy.json` and `registries.d`

```bash
sudo cp /etc/containers/policy.json /etc/containers/policy.json.bak

sudo jq --arg repo "ghcr.io/${GITHUB_USER}/${REPO_NAME}" \
        --arg keypath "/etc/pki/containers/${GITHUB_USER}-${REPO_NAME}.pub" \
        '.transports.docker[$repo] = [{"type": "sigstoreSigned", "keyPath": $keypath, "signedIdentity": {"type": "matchRepository"}}]' \
        /etc/containers/policy.json | sudo tee /etc/containers/policy.json.tmp > /dev/null

sudo mv /etc/containers/policy.json.tmp /etc/containers/policy.json
```

Create attachment config in `/etc/containers/registries.d/`:
```bash
sudo tee "/etc/containers/registries.d/${GITHUB_USER}-${REPO_NAME}.yaml" > /dev/null << EOF
docker:
  ghcr.io/${GITHUB_USER}/${REPO_NAME}:
    use-sigstore-attachments: true
EOF
```

**Verification:**
```bash
jq -e ".transports.docker[\"ghcr.io/${GITHUB_USER}/${REPO_NAME}\"]" /etc/containers/policy.json
```

---

## Phase 5: Dotfile Quarantine & Signed Atomic Rebase

### 5.1 Non-Destructive Quarantine of Conflicting GNOME User Configs
```bash
export BACKUP_DIR="$HOME/.gnome-migration-backup-$(date +%Y%m%d)"
mkdir -p "${BACKUP_DIR}/gtk-3.0" \
         "${BACKUP_DIR}/gtk-4.0" \
         "${BACKUP_DIR}/xdg-desktop-portal" \
         "${BACKUP_DIR}/autostart"

# 1. Quarantine custom GTK CSS files (preserve settings.ini and bookmarks!)
[ -f ~/.config/gtk-3.0/gtk.css ] && mv ~/.config/gtk-3.0/gtk.css "${BACKUP_DIR}/gtk-3.0/"
[ -f ~/.config/gtk-3.0/gtk-dark.css ] && mv ~/.config/gtk-3.0/gtk-dark.css "${BACKUP_DIR}/gtk-3.0/"
[ -f ~/.config/gtk-4.0/gtk.css ] && mv ~/.config/gtk-4.0/gtk.css "${BACKUP_DIR}/gtk-4.0/"
[ -f ~/.config/gtk-4.0/gtk-dark.css ] && mv ~/.config/gtk-4.0/gtk-dark.css "${BACKUP_DIR}/gtk-4.0/"

# 2. Quarantine user-level portal overrides
mv ~/.config/xdg-desktop-portal/*.conf "${BACKUP_DIR}/xdg-desktop-portal/" 2>/dev/null || true

# 3. Quarantine GNOME-specific autostart entries
for desktop_file in ~/.config/autostart/*.desktop; do
    [ -e "$desktop_file" ] || continue
    if grep -qiE "gnome|gsconnect|extension" "$desktop_file"; then
        mv "$desktop_file" "${BACKUP_DIR}/autostart/"
    fi
done
```

### 5.2 Reset Local Package Layering & Execute the Signed Rebase
```bash
# 1. Remove any locally layered packages from the staging deployment
sudo rpm-ostree reset

# 2. Execute the signed rebase to your custom GHCR image
sudo rpm-ostree rebase "ostree-image-signed:docker://ghcr.io/${GITHUB_USER}/${REPO_NAME}:latest"
```

**Pre-Reboot Verification:**
- Top staged deployment shows `ostree-image-signed:docker://ghcr.io/<username>/bazzite-cosmic:latest`.
- Signature is valid / verified via sigstore.
- Previous `bazzite-gnome` deployment is directly underneath with `Pinned: yes`.

### 5.3 Reboot into COSMIC
```bash
systemctl reboot
```
