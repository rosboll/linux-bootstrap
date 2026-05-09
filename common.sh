#!/usr/bin/env bash
# common.sh — sourced by all scripts. Provides logging helpers and host lookup.

# Bash 4+ is required for mapfile/readarray
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

# Look up fields in hosts.conf.
# Usage: lookup_host_field <field>  where field is "role" or "is_pentest"
lookup_host_field() {
    local field="$1"
    local hostname
    hostname=$(hostname)
    local conf
    conf="$(dirname "${BASH_SOURCE[0]}")/hosts.conf"

    local line=""
    if [ -f "$conf" ]; then
        line=$(grep -v '^\s*#' "$conf" | grep -v '^\s*$' | awk -v h="$hostname" '$1 == h { print; exit }')
    fi

    if [ -z "$line" ]; then
        case "$field" in
            role)       echo "daily" ;;
            is_pentest) echo "no" ;;
            is_vm)      echo "no" ;;
            *)          echo "" ;;
        esac
        return
    fi

    case "$field" in
        role)       echo "$line" | awk '{print $2}' ;;
        is_pentest) echo "$line" | awk '{print $3}' ;;
        is_vm)      echo "$line" | awk '{print $4}' ;;
        *)          echo "" ;;
    esac
}

is_pentest_host() {
    [ "$(lookup_host_field is_pentest)" = "yes" ]
}

is_vm_host() {
    [ "$(lookup_host_field is_vm)" = "yes" ]
}

# Check if an apt package is installed (status "ok installed").
apt_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

# Check if the current user belongs to a group.
in_group() {
    id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
}
