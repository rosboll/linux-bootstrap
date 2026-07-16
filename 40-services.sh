#!/usr/bin/env bash
# 40-services.sh — Adds $USER to docker, libvirt and kvm groups; activates
# libvirt's default network; ensures docker.service is enabled.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
require_sudo

# Docker is on both profiles; the rest (wireshark, libvirt, kvm) are desktop-only
# because the underlying packages aren't installed on the server profile.
groups_to_check=(docker)
if is_desktop; then
    groups_to_check+=(wireshark libvirt kvm)
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

# 2. Activate libvirt default network. Desktop-only — servers use their
#    hypervisor's networking (Proxmox bridges, OCI VCN, etc.) instead of
#    libvirt's NAT. The 'default' network is created by libvirt-daemon-system
#    on install; gate on its existence so a half-installed system doesn't
#    trip set -e.
if is_desktop && command -v virsh > /dev/null 2>&1; then
    if sudo virsh net-list --all --name 2>/dev/null | grep -qx default; then
        if sudo virsh net-info default 2>/dev/null | grep -qE "Active:[[:space:]]*yes"; then
            skip "libvirt default network already active"
        else
            log "Starting libvirt default network"
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
    else
        warn "libvirt 'default' network not defined — skipping. Re-install libvirt-daemon-system if you expected it."
    fi
fi

# 3. Ensure docker.service is enabled. Skipped in smoke mode — the container
#    does not run systemd as PID 1, so 'systemctl enable --now' would fail.
if is_smoke_test; then
    skip "Smoke test mode — skipping docker.service enable"
elif systemctl cat docker.service > /dev/null 2>&1; then
    if systemctl is-enabled docker.service > /dev/null 2>&1; then
        skip "docker.service already enabled"
    else
        log "Enabling docker.service"
        sudo systemctl enable --now docker.service
        ok "docker started"
    fi
fi

ok "Services configured"
