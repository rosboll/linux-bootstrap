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

log "Installing ${#to_install[@]} packages: ${to_install[*]}"
apt_wait_for_lock
sudo apt install -y "${to_install[@]}"
ok "Package installation complete"

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
