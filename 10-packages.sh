#!/usr/bin/env bash
# 10-packages.sh — Installs apt packages listed in packages.txt. Also
# configures the Microsoft VS Code repository so that the 'code' package
# resolves.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
require_sudo

# 1. Configure third-party repositories before the package list is read.
#    Suites are hardcoded — update when bumping Debian release.

configure_apt_repo "vscode" \
    "https://packages.microsoft.com/keys/microsoft.asc" \
    "https://packages.microsoft.com/repos/code" \
    "stable" "main" "amd64 arm64 armhf"

configure_apt_repo "hashicorp" \
    "https://apt.releases.hashicorp.com/gpg" \
    "https://apt.releases.hashicorp.com" \
    "trixie" "main" "amd64 arm64"

configure_apt_repo "github-cli" \
    "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
    "https://cli.github.com/packages" \
    "stable" "main" "amd64 arm64"

apt_wait_for_lock
log "Updating apt cache"
sudo apt update

# Pre-seed Wireshark's debconf question so the install is non-interactive and
# non-root users can capture packets via the 'wireshark' group.
# 40-services.sh adds $USER to that group.
echo "wireshark-common wireshark-common/install-setuid boolean true" \
    | sudo debconf-set-selections

# 2. Read packages. Strip trailing comments and blank lines.
mapfile -t packages < <(sed -E 's/[[:space:]]*#.*//; /^[[:space:]]*$/d' "$DIR/packages.txt")

# Filter out already-installed packages
to_install=()
for pkg in "${packages[@]}"; do
    if apt_installed "$pkg"; then
        skip "$pkg already installed"
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
    if ! is_smoke_test; then
        read -r -p "Press Enter to continue, or Ctrl+C to abort... "
    fi
fi

log "Installing ${#to_install[@]} packages: ${to_install[*]}"
apt_wait_for_lock
sudo apt install -y "${to_install[@]}"
ok "Package installation complete"

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
    else
        err "Check /etc/resolv.conf and your network configuration."
    fi
    exit 1
fi

# 3. Pin nc to the OpenBSD variant. Both netcat-openbsd and netcat-traditional
#    register /bin/nc.openbsd and /bin/nc.traditional under /etc/alternatives/nc.
#    We want the OpenBSD one (better IPv6, -e flag for pentesting).
if [ -e /bin/nc.openbsd ] \
   && command -v update-alternatives > /dev/null 2>&1 \
   && [ "$(readlink -f /etc/alternatives/nc 2>/dev/null)" != "/bin/nc.openbsd" ]; then
    log "Pinning nc to OpenBSD variant"
    sudo update-alternatives --set nc /bin/nc.openbsd
    ok "nc -> /bin/nc.openbsd"
fi
