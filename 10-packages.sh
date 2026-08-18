#!/usr/bin/env bash
# 10-packages.sh — Installs apt packages. Profile-aware:
#   desktop (default): packages/base.txt + packages/desktop.txt
#   server:            packages/base.txt + packages/server.txt
# Also configures third-party apt repositories (VS Code, HashiCorp, GitHub CLI)
# that are needed to resolve packages listed in the manifests.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
require_sudo

profile=$(bootstrap_profile)
log "Profile: $profile ($(os_id) $(os_codename))"

# 1. Third-party apt repositories.
#
# GitHub CLI is shared across profiles (gh is in base.txt).
# Microsoft VS Code repo only when 'code' will be installed (desktop).
# HashiCorp is desktop-only (terraform lives in desktop.txt).
# HashiCorp's repo publishes per-distro suites — pick trixie / noble / jammy
# etc. from /etc/os-release rather than hardcoding.

configure_apt_repo "github-cli" \
    "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
    "https://cli.github.com/packages" \
    "stable" "main" "amd64 arm64"

if is_desktop; then
    configure_apt_repo "vscode" \
        "https://packages.microsoft.com/keys/microsoft.asc" \
        "https://packages.microsoft.com/repos/code" \
        "stable" "main" "amd64 arm64 armhf"

    hashicorp_suite=$(os_codename)
    if [ -z "$hashicorp_suite" ]; then
        err "Could not determine distribution codename from /etc/os-release."
        err "HashiCorp apt repo needs a suite (e.g. trixie, noble, jammy)."
        exit 1
    fi
    configure_apt_repo "hashicorp" \
        "https://apt.releases.hashicorp.com/gpg" \
        "https://apt.releases.hashicorp.com" \
        "$hashicorp_suite" "main" "amd64 arm64"
fi

apt_wait_for_lock
log "Updating apt cache"
sudo apt update

# 2. Pre-seed debconf answers so apt install runs non-interactive.
#
# Wireshark (desktop only): true → dumpcap setuid, users in the
# 'wireshark' group can capture without sudo. 40-services.sh adds $USER
# there. Server profile uses tcpdump (base.txt) and does not install
# wireshark or tshark, so no pre-seed is needed there.
if is_desktop; then
    echo "wireshark-common wireshark-common/install-setuid boolean true" \
        | sudo debconf-set-selections
fi

# needrestart on Ubuntu prompts interactively during upgrades to restart
# services — that breaks unattended apt runs. Flip it to non-interactive
# ('a' = automatically restart).
#
# Two-part fix so this works whether needrestart is preinstalled OR gets
# installed by the apt run below (Debian server profile pulls it in fresh;
# Ubuntu ships it):
#
# (a) Drop-in file — read the moment needrestart first runs, even if it
#     was installed in the same apt transaction we're about to trigger.
#     DEBIAN_FRONTEND=noninteractive doesn't help here: needrestart uses
#     its own whiptail dialog, not debconf.
#
# (b) Rewrite the main config too, so the setting is visible in the
#     canonical place after the run (matches what `dpkg-reconfigure
#     needrestart` would produce).
sudo install -d -m 0755 /etc/needrestart/conf.d
sudo tee /etc/needrestart/conf.d/50-linux-bootstrap.conf > /dev/null <<'EOF'
# Written by linux-bootstrap 10-packages.sh
# Force automatic service restarts so apt runs stay non-interactive.
$nrconf{restart} = 'a';
EOF

if apt_installed needrestart && [ -f /etc/needrestart/needrestart.conf ]; then
    if ! grep -qE "^\s*\\\$nrconf\{restart\}\s*=\s*'a'" /etc/needrestart/needrestart.conf; then
        log "Setting needrestart to non-interactive (auto-restart)"
        sudo sed -i -E "s|^#?\s*\\\$nrconf\{restart\}\s*=\s*'.'|\$nrconf{restart} = 'a'|" \
            /etc/needrestart/needrestart.conf
    fi
fi

# 3. Read the package manifests. Base is always loaded; profile overlay
#    (desktop.txt or server.txt) is added on top. Comments and blank lines
#    are stripped.
manifests=("$DIR/packages/base.txt" "$DIR/packages/${profile}.txt")
for m in "${manifests[@]}"; do
    if [ ! -f "$m" ]; then
        err "Missing package manifest: $m"
        exit 1
    fi
done
mapfile -t packages < <(sed -E 's/[[:space:]]*#.*//; /^[[:space:]]*$/d' "${manifests[@]}")

# Filter out already-installed packages and known third-party conflicts.
to_install=()
for pkg in "${packages[@]}"; do
    if apt_installed "$pkg"; then
        skip "$pkg already installed"
    elif [ "$pkg" = "docker.io" ] && docker_ce_installed; then
        skip "docker.io skipped — docker-ce (docker.com repo) already installed; would file-conflict on docker-buildx"
    else
        to_install+=("$pkg")
    fi
done

if [ ${#to_install[@]} -eq 0 ]; then
    ok "All packages already installed"
    exit 0
fi

# Tailscale + resolvconf conflict guard.
# When tailscaled is running on a host that gains the resolvconf package, it
# rewrites /etc/resolv.conf to point solely at MagicDNS (100.100.100.100).
# Tailnets with no global nameservers configured then lose external DNS —
# MagicDNS refuses to recurse for anything outside the tailnet. We can't
# fix this from a host script (the durable fix is in the tailnet admin
# panel), so warn and pause instead. Postflight below verifies DNS afterwards.
resolvconf_incoming=0
for pkg in "${to_install[@]}"; do
    if [ "$pkg" = "resolvconf" ]; then
        resolvconf_incoming=1
        break
    fi
done
if [ "$resolvconf_incoming" -eq 1 ] && tailscale_active; then
    warn "Tailscale is running AND resolvconf is about to be installed."
    warn "This can break external DNS if your tailnet has no global"
    warn "nameservers configured. Mitigations (pick one):"
    warn ""
    warn "  a) Add global nameservers in the tailnet admin panel, then"
    warn "     continue — DNS keeps working via MagicDNS:"
    warn "       https://login.tailscale.com/admin/dns"
    warn ""
    warn "  b) Disable Tailscale DNS management on this host, then continue"
    warn "     — DNS falls back to DHCP/NetworkManager:"
    warn "       sudo tailscale set --accept-dns=false"
    warn ""
    warn "If unsure, (b) is safe. Postflight will verify DNS after apt install."
    read -r -p "Press Enter to continue, or Ctrl+C to abort... "
fi

log "Installing ${#to_install[@]} packages: ${to_install[*]}"
apt_wait_for_lock
# DEBIAN_FRONTEND=noninteractive is a belt-and-braces safety net: any
# debconf question we haven't explicitly pre-seeded gets the package's
# default answer instead of firing a whiptail dialog. Without this, an
# unpreseeded prompt hangs behind run-all.sh's tee pipe with unresponsive
# arrow/tab keys (whiptail needs a tty on stdout to redraw properly).
sudo DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}"
ok "Package installation complete"

# Self-heal after a fresh resolvconf install. NetworkManager on Debian 13
# integrates with resolvconf automatically once it's present, but it only
# republishes DNS on connection events — so right after apt drops resolvconf
# in, the spool at /run/resolvconf/resolv.conf is header-only and
# /etc/resolv.conf (now a symlink to it) has no nameservers. `resolvconf -u`
# regenerates it from the current NM data and unblocks the postflight below.
# Debugged 2026-08-14 on x9.
if [ "$resolvconf_incoming" -eq 1 ] \
   && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log "Syncing resolvconf with NetworkManager (fresh resolvconf install)"
    sudo resolvconf -u
fi

# Postflight DNS check. Installing resolvconf (see guard above) or any other
# package that shuffles /etc/resolv.conf can leave DNS broken. Fail fast with
# clear recovery steps rather than let 20-locale.sh or 30-shell.sh hit the
# fallout with a less informative error.
if ! dns_works; then
    err "External DNS resolution failed after apt install (getent hosts github.com)."
    if tailscale_active; then
        err "Tailscale is running. Likely cause: /etc/resolv.conf now points"
        err "at MagicDNS (100.100.100.100) only, and your tailnet has no"
        err "global nameservers configured — so MagicDNS refuses to recurse."
        err ""
        err "Quick fix (disable Tailscale DNS management):"
        err "    sudo tailscale set --accept-dns=false"
        err "    sudo systemctl restart tailscaled"
        err "    getent hosts github.com    # verify"
        err ""
        err "Or keep MagicDNS by adding global nameservers upstream:"
        err "    https://login.tailscale.com/admin/dns"
    elif [ "$resolvconf_incoming" -eq 1 ]; then
        err "resolvconf was just installed. If NetworkManager isn't feeding it,"
        err "try:  sudo resolvconf -u  (or restart NetworkManager)."
        err "Then verify:  cat /etc/resolv.conf ; getent hosts github.com"
    else
        err "Check /etc/resolv.conf and your network configuration."
    fi
    exit 1
fi

# 4. Pin nc to the OpenBSD variant. Both netcat-openbsd and netcat-traditional
#    register /bin/nc.openbsd and /bin/nc.traditional under /etc/alternatives/nc.
#    We want the OpenBSD one: better IPv6 support, -N (shutdown on EOF), and
#    it's what most tooling and write-ups assume. Note Debian builds it
#    WITHOUT -e — reach for ncat (nmap's netcat) when you need that.
if [ -e /bin/nc.openbsd ] \
   && command -v update-alternatives > /dev/null 2>&1 \
   && [ "$(readlink -f /etc/alternatives/nc 2>/dev/null)" != "/bin/nc.openbsd" ]; then
    log "Pinning nc to OpenBSD variant"
    sudo update-alternatives --set nc /bin/nc.openbsd
    ok "nc -> /bin/nc.openbsd"
fi
