#!/usr/bin/env bash
# 40-services.sh — Adds $USER to docker, libvirt and kvm groups; activates
# libvirt's default network; ensures docker.service is enabled. Virtualization
# steps are skipped on hosts marked is_vm=yes in hosts.conf.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
require_sudo

# Decide which groups to consider. docker and wireshark are always relevant;
# libvirt and kvm are skipped on VM hosts (where the packages are not
# installed anyway).
groups_to_check=(docker wireshark)
if is_vm_host; then
    skip "Running on a VM host — skipping libvirt/kvm groups and network"
else
    groups_to_check+=(libvirt kvm)
fi

# 1. Groups
for group in "${groups_to_check[@]}"; do
    if getent group "$group" > /dev/null 2>&1; then
        if in_group "$group"; then
            skip "$USER already in group $group"
        else
            log "Adding $USER to $group"
            sudo usermod -aG "$group" "$USER"
            ok "Added to $group (requires log out / log in)"
        fi
    else
        skip "Group $group does not exist (package not installed?)"
    fi
done

# 2. Activate libvirt default network — only on non-VM hosts
if ! is_vm_host && command -v virsh > /dev/null 2>&1; then
    if sudo virsh net-info default 2>/dev/null | grep -qE "Active:[[:space:]]*yes"; then
        skip "libvirt default network already active"
    else
        log "Starting libvirt default network"
        # net-start fails if already active; tolerate that.
        sudo virsh net-start default 2>/dev/null || true
        ok "libvirt default network started"
    fi

    if sudo virsh net-info default 2>/dev/null | grep -qE "Autostart:[[:space:]]*yes"; then
        skip "libvirt default network autostart already enabled"
    else
        log "Enabling autostart for libvirt default network"
        sudo virsh net-autostart default
        ok "Autostart enabled"
    fi
fi

# 3. Ensure docker.service is enabled. Note that docker.io ships a SysV-style
#    init.d script that systemd wraps, so the unit is named docker.service
#    regardless.
if systemctl list-unit-files docker.service 2>/dev/null | grep -q docker.service; then
    if systemctl is-enabled docker.service > /dev/null 2>&1; then
        skip "docker.service already enabled"
    else
        log "Enabling docker.service"
        sudo systemctl enable --now docker.service
        ok "docker started"
    fi
fi

ok "Services configured"
