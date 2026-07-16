#!/usr/bin/env bash
# common.sh — sourced by all scripts. Provides logging helpers and host lookup.

# Bash 4+ is required for mapfile/readarray. Trixie ships bash 5.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: this script requires bash 4 or newer." >&2
    exit 1
fi

# Colours (only when stdout is a terminal)
if [ -t 1 ]; then
    BLUE=$'\033[0;34m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    RED=$'\033[0;31m'
    GRAY=$'\033[0;90m'
    NC=$'\033[0m'
else
    BLUE=""; GREEN=""; YELLOW=""; RED=""; GRAY=""; NC=""
fi

log()  { printf "%s[*]%s %s\n" "$BLUE"   "$NC" "$1"; }
ok()   { printf "%s[+]%s %s\n" "$GREEN"  "$NC" "$1"; }
warn() { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$1"; }
err()  { printf "%s[-]%s %s\n" "$RED"    "$NC" "$1" >&2; }
skip() { printf "%s[=]%s %s\n" "$GRAY"   "$NC" "$1"; }

# Refuse to run as root — these scripts assume a normal user with sudo.
# Running as root would create files owned by root in the home directory and
# break things later.
require_normal_user() {
    if [ "$(id -u)" -eq 0 ]; then
        err "Do not run this script as root. Run as your normal user; sudo is invoked where needed."
        exit 1
    fi
}

# Verify sudo is usable (cached or password prompt). Fail fast if not.
require_sudo() {
    if ! sudo -v; then
        err "sudo authentication failed. Aborting."
        exit 1
    fi
}

# Smoke-test mode skips operations that need network credentials we don't
# have inside a container (cloning private repos, talking to GitHub via SSH,
# touching real hardware). The Containerfile sets BOOTSTRAP_SMOKE=1.
is_smoke_test() {
    [ "${BOOTSTRAP_SMOKE:-0}" = "1" ]
}

# Check if an apt package is installed (status "ok installed").
apt_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

# Wait for apt/dpkg locks to be released. KDE's packagekitd and unattended
# upgrades both grab these locks periodically. Times out after 5 minutes —
# unattended-upgrades on a fresh system can hold the lock that long.
apt_wait_for_lock() {
    local timeout=300
    local elapsed=0
    local locks=(
        /var/lib/apt/lists/lock
        /var/lib/dpkg/lock
        /var/lib/dpkg/lock-frontend
    )

    while [ "$elapsed" -lt "$timeout" ]; do
        local locked=0
        for lock in "${locks[@]}"; do
            if sudo fuser "$lock" > /dev/null 2>&1; then
                locked=1
                break
            fi
        done
        if [ "$locked" -eq 0 ]; then
            return 0
        fi
        if [ "$elapsed" -eq 0 ]; then
            warn "Waiting for apt lock to be released (held by packagekitd or similar)..."
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    err "apt lock still held after ${timeout}s. Holding process(es):"
    for lock in "${locks[@]}"; do
        if sudo fuser "$lock" > /dev/null 2>&1; then
            sudo fuser -v "$lock" 2>&1 | sed 's/^/    /' >&2
        fi
    done
    err "Try: sudo systemctl stop packagekit unattended-upgrades"
    return 1
}

# Configure a DEB822 apt source backed by a dearmored signing key. Idempotent:
# returns immediately if both files already exist.
# Usage: configure_apt_repo <name> <key-url> <repo-url> <suite> <components> <archs>
configure_apt_repo() {
    local name="$1" key_url="$2" repo_url="$3"
    local suites="$4" components="$5" architectures="$6"
    local keyring="/etc/apt/keyrings/${name}.gpg"
    local sources="/etc/apt/sources.list.d/${name}.sources"

    if [ -f "$keyring" ] && [ -f "$sources" ]; then
        skip "${name} apt repo already configured"
        return
    fi

    log "Configuring apt repo: ${name}"

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
    wget -qO- "$key_url" | sudo gpg --dearmor --yes -o "$keyring"
    sudo chmod 0644 "$keyring"

    sudo tee "$sources" > /dev/null <<EOF
Types: deb
URIs: ${repo_url}
Suites: ${suites}
Components: ${components}
Architectures: ${architectures}
Signed-By: ${keyring}
EOF
    ok "${name} apt repo configured"
}

# Check if the current user belongs to a group.
in_group() {
    id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
}

# Whether tailscaled is running as a systemd service. Tailscale reacts to
# resolvconf install/removal by rewriting /etc/resolv.conf to point at
# MagicDNS (100.100.100.100) only. If the tailnet has no global nameservers
# configured in the admin panel, external DNS then fails because MagicDNS
# refuses to recurse. 10-packages.sh uses this to warn before the change
# lands. See README "Tailscale coexistence".
tailscale_active() {
    systemctl is-active --quiet tailscaled 2>/dev/null
}

# Whether external DNS resolution currently works. Uses getent (nsswitch) so
# it reflects what apt / curl / go install will actually experience.
dns_works() {
    getent hosts github.com > /dev/null 2>&1
}

# Bootstrap profile — "desktop" (default) or "server". Selected by run-all.sh
# via BOOTSTRAP_PROFILE=server (set by --server). Every script that behaves
# differently between the two consults this. Anything unset or unrecognised
# falls back to "desktop" so the pre-profile behaviour is preserved.
bootstrap_profile() {
    case "${BOOTSTRAP_PROFILE:-desktop}" in
        server)  echo server ;;
        *)       echo desktop ;;
    esac
}
is_desktop() { [ "$(bootstrap_profile)" = "desktop" ]; }
is_server()  { [ "$(bootstrap_profile)" = "server" ]; }

# OS detection — /etc/os-release is the single source of truth on all
# systemd distros. We keep it read-only; nothing here writes to it.
os_id() {
    ( . /etc/os-release 2>/dev/null && printf '%s' "${ID:-}" )
}
is_debian() { [ "$(os_id)" = "debian" ]; }
is_ubuntu() { [ "$(os_id)" = "ubuntu" ]; }

# Distribution codename (e.g. trixie, noble, jammy). Used to pick the
# right suite for third-party apt repos that publish per-release
# (HashiCorp, Microsoft VS Code stable is 'stable' so unaffected).
os_codename() {
    ( . /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}" )
}
