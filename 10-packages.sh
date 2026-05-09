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
configure_vscode_repo() {
    local keyring="/etc/apt/keyrings/packages.microsoft.gpg"
    local sources="/etc/apt/sources.list.d/vscode.sources"

    if [ -f "$keyring" ] && [ -f "$sources" ]; then
        skip "VS Code repo already configured"
        return
    fi

    log "Configuring Microsoft VS Code repository"

    # Make sure prerequisites for adding a signed repo are present.
    local prereqs=()
    apt_installed wget || prereqs+=(wget)
    apt_installed gpg  || prereqs+=(gpg)
    if [ ${#prereqs[@]} -gt 0 ]; then
        apt_wait_for_lock
        sudo apt update
        apt_wait_for_lock
        sudo apt install -y "${prereqs[@]}"
    fi

    sudo install -d -m 0755 /etc/apt/keyrings
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
        | sudo gpg --dearmor --yes -o "$keyring"
    sudo chmod 0644 "$keyring"

    # DEB822 format (preferred on Trixie)
    sudo tee "$sources" > /dev/null <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64 arm64 armhf
Signed-By: $keyring
EOF
    ok "VS Code repo configured"
}

configure_hashicorp_repo() {
    local keyring="/etc/apt/keyrings/hashicorp-archive-keyring.gpg"
    local sources="/etc/apt/sources.list.d/hashicorp.sources"

    if [ -f "$keyring" ] && [ -f "$sources" ]; then
        skip "HashiCorp repo already configured"
        return
    fi

    log "Configuring HashiCorp apt repository (for terraform)"

    local prereqs=()
    apt_installed wget || prereqs+=(wget)
    apt_installed gpg  || prereqs+=(gpg)
    if [ ${#prereqs[@]} -gt 0 ]; then
        apt_wait_for_lock
        sudo apt update
        apt_wait_for_lock
        sudo apt install -y "${prereqs[@]}"
    fi

    sudo install -d -m 0755 /etc/apt/keyrings
    wget -qO- https://apt.releases.hashicorp.com/gpg \
        | sudo gpg --dearmor --yes -o "$keyring"
    sudo chmod 0644 "$keyring"

    # Hardcoded suite — update when upgrading to a new Debian release.
    sudo tee "$sources" > /dev/null <<EOF
Types: deb
URIs: https://apt.releases.hashicorp.com
Suites: trixie
Components: main
Architectures: amd64 arm64
Signed-By: $keyring
EOF
    ok "HashiCorp repo configured"
}

configure_vscode_repo
configure_hashicorp_repo

apt_wait_for_lock
log "Updating apt cache"
sudo apt update

# Pre-seed Wireshark's debconf question so the install is non-interactive and
# non-root users can capture packets via the 'wireshark' group.
# 40-services.sh adds $USER to that group.
echo "wireshark-common wireshark-common/install-setuid boolean true" \
    | sudo debconf-set-selections

# 2. Read packages. Lines marked '# vm-skip' are skipped on hosts where
#    is_vm=yes. Strip trailing comments only after that filter.
skip_vm_packages=0
if is_vm_host; then
    skip_vm_packages=1
    log "Running on a VM host — skipping packages marked 'vm-skip'"
fi

mapfile -t packages < <(
    while IFS= read -r line; do
        # Drop full-line comments and blank lines
        case "$line" in
            ''|\#*) continue ;;
        esac
        # Drop vm-skip lines when on a VM
        if [ "$skip_vm_packages" -eq 1 ] && [[ "$line" == *"# vm-skip"* ]]; then
            continue
        fi
        # Strip trailing comments
        printf '%s\n' "$line" | sed -E 's/[[:space:]]*#.*$//'
    done < "$DIR/packages.txt" \
    | grep -v '^[[:space:]]*$'
)

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
