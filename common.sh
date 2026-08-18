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

# Verify sudo is usable. Prefer the non-interactive path first — this
# succeeds silently for users with NOPASSWD (common on cloud images like
# OCI Ubuntu, where 'ubuntu' has `NOPASSWD: ALL`) or with a fresh sudo
# credential cache. Falling back to `sudo -v` handles the workstation
# case where the user actually has to type a password.
#
# Why not just `sudo -v` alone: on hosts where the user has BOTH a
# passworded sudoers rule AND a NOPASSWD rule (again, OCI ubuntu:
# `(ALL:ALL) ALL` + `(ALL) NOPASSWD: ALL`), some sudo versions'
# validate path still prompts for the password rule, even though the
# NOPASSWD rule would apply to any actual command. `sudo -n true`
# probes the effective policy directly.
require_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    if ! sudo -v; then
        err "sudo authentication failed. Aborting."
        exit 1
    fi
}

# Check if an apt package is installed (status "ok installed").
apt_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

# Wait for apt/dpkg locks to be released. KDE's packagekitd and
# unattended-upgrades both grab these locks periodically. Cloud images
# (OCI, AWS, etc.) also fire cloud-init + apt-daily(-upgrade) within the
# first ~15 min after boot, so we allow up to 15 minutes here.
#
# Prints a heartbeat every 30s with elapsed time so a long wait doesn't
# look like a hang under run-all.sh's tee pipe.
apt_wait_for_lock() {
    local timeout=900   # 15 min — covers first-boot cloud-init storms
    local elapsed=0
    local last_print=0
    local locked lock
    local locks=(
        /var/lib/apt/lists/lock
        /var/lib/dpkg/lock
        /var/lib/dpkg/lock-frontend
    )

    while [ "$elapsed" -lt "$timeout" ]; do
        locked=0
        for lock in "${locks[@]}"; do
            if sudo fuser "$lock" > /dev/null 2>&1; then
                locked=1
                break
            fi
        done
        if [ "$locked" -eq 0 ]; then
            [ "$elapsed" -gt 0 ] && ok "apt lock released after ${elapsed}s"
            return 0
        fi
        # First hit — announce who's holding it, then heartbeat every 30s.
        if [ "$elapsed" -eq 0 ]; then
            warn "Waiting for apt lock (up to ${timeout}s). Holder(s):"
            for lock in "${locks[@]}"; do
                if sudo fuser "$lock" > /dev/null 2>&1; then
                    sudo fuser -v "$lock" 2>&1 | sed 's/^/    /' >&2
                fi
            done
        elif [ $((elapsed - last_print)) -ge 30 ]; then
            warn "  ... still waiting (${elapsed}s elapsed)"
            last_print=$elapsed
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
    err "Try: sudo systemctl stop packagekit unattended-upgrades apt-daily.service apt-daily-upgrade.service"
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

# Whether docker-ce (from download.docker.com) is already installed on this
# box. Any of docker-ce, docker-ce-cli, containerd.io, or
# docker-buildx-plugin means Debian's docker.io would collide on
# /usr/libexec/docker/cli-plugins/docker-buildx during unpack. Existing
# docker-ce installs on long-lived servers should be respected — we just
# skip docker.io in that case; the docker group and CLI are already there.
docker_ce_installed() {
    # 'local' is critical here — the caller in 10-packages.sh iterates
    # with a variable also named 'pkg'. Without local, this loop's last
    # iteration would clobber the outer 'pkg' to 'docker-buildx-plugin',
    # causing that name to end up in the install list even though it's
    # not in any manifest. Debugged the hard way on an OCI Ubuntu box
    # with no docker of any kind installed.
    local pkg
    for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin; do
        apt_installed "$pkg" && return 0
    done
    return 1
}
