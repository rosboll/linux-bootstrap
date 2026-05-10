#!/usr/bin/env bash
# 50-yubikey.sh — Configures PAM so a YubiKey can be used for sudo and SDDM.
# Key registration (pamu2fcfg) is inherently manual and must be done with each
# physical key plugged in — this script pauses to let you do it.
# Skipped on hosts marked is_vm=yes (no physical YubiKey is plugged into a VM).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user

if is_vm_host || is_smoke_test; then
    skip "VM / smoke-test host — skipping YubiKey PAM configuration"
    exit 0
fi

require_sudo

# 1. Verify required packages are installed
for pkg in libpam-u2f pamu2fcfg yubikey-manager; do
    if ! apt_installed "$pkg"; then
        err "$pkg is missing. Run 10-packages.sh first."
        exit 1
    fi
done

# 2. Ensure the u2f_keys directory exists with tight perms
U2F_DIR="$HOME/.config/Yubico"
U2F_KEYS="$U2F_DIR/u2f_keys"
mkdir -p "$U2F_DIR"
chmod 700 "$U2F_DIR"
[ -f "$U2F_KEYS" ] && chmod 600 "$U2F_KEYS"

# 3. If no keys are registered yet, prompt for the manual step
if [ ! -s "$U2F_KEYS" ]; then
    warn "No registered YubiKeys found."
    echo
    echo "  For each key you want to register:"
    echo "    1. Insert the key"
    echo "    2. Run, for the FIRST key (creates the file):"
    echo "         pamu2fcfg > $U2F_KEYS"
    echo "       Or for ADDITIONAL keys (appends):"
    echo "         pamu2fcfg -n >> $U2F_KEYS"
    echo "    3. Touch the key when it blinks"
    echo
    read -r -p "Press Enter once at least one key is registered (or Ctrl+C to abort)... "
fi

if [ ! -s "$U2F_KEYS" ]; then
    err "No keys registered. Aborting."
    exit 1
fi

# 4. Add pam_u2f.so to sudo and sddm. 'sufficient' means a YubiKey is enough,
#    while a password still works as fallback. Switch to 'required' if you
#    want the YubiKey to be mandatory. 'cue' makes pam_u2f print "Please
#    touch the device" instead of waiting silently.
PAM_U2F_LINE='auth sufficient pam_u2f.so cue'

add_pam_u2f() {
    local pam_file="$1"
    if [ ! -f "$pam_file" ]; then
        skip "$pam_file does not exist — skipping"
        return
    fi
    if grep -q "pam_u2f.so" "$pam_file"; then
        skip "pam_u2f.so already configured in $pam_file"
        return
    fi
    if ! grep -q '^@include common-auth' "$pam_file"; then
        err "$pam_file has no '@include common-auth' anchor — refusing to inject pam_u2f blindly"
        return 1
    fi
    log "Adding pam_u2f.so to $pam_file"
    sudo sed -i "/^@include common-auth/i ${PAM_U2F_LINE}" "$pam_file"
    if ! grep -qF "${PAM_U2F_LINE}" "$pam_file"; then
        err "sed completed but $pam_file does not contain the pam_u2f line — investigate before re-running"
        return 1
    fi
    ok "Added to $pam_file"
}

add_pam_u2f /etc/pam.d/sudo
add_pam_u2f /etc/pam.d/sddm

warn "Test sudo in a NEW terminal before logging out, in case PAM is broken."
ok "YubiKey PAM configuration complete"
