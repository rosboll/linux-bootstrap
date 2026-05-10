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

# Validate the username column. pam_u2f looks up credentials by the user it
# is authenticating; if the line doesn't start with '<user>:' the lookup
# silently fails and PAM falls through to the password prompt with no clue
# why. This usually happens when pamu2fcfg was called with -n for the FIRST
# key (the -n flag is for SUBSEQUENT keys only).
u2f_first_field=$(awk -F: 'NR==1 {print $1}' "$U2F_KEYS")
if [ -z "$u2f_first_field" ]; then
    err "$U2F_KEYS starts with ':' — username column is empty."
    err "This happens when pamu2fcfg -n was used for the first key. Fix:"
    err "    sed -i.bak 's/^:/$USER:/' $U2F_KEYS"
    exit 1
fi
if [ "$u2f_first_field" != "$USER" ]; then
    err "$U2F_KEYS first column is '$u2f_first_field', expected '$USER'."
    err "pam_u2f matches by the authenticating user, so this won't work for sudo/sddm."
    err "Either re-register or rewrite the username:"
    err "    sed -i.bak 's/^${u2f_first_field}:/$USER:/' $U2F_KEYS"
    exit 1
fi

# 4. Add pam_u2f.so to the relevant PAM stacks.
#
#    'sufficient' means a YubiKey is enough; password still works as fallback.
#    Two friction levels:
#
#    - sudo:           cue                       (just touch — already proved
#                                                 identity to log in)
#    - sddm / kde:     cue + pinverification=1   (PIN + touch — physical
#                                                 access is the threat at the
#                                                 login/lock screen)
#
#    'cue' prints "Please touch the device" instead of waiting silently.
#    'pinverification=1' requires the FIDO2 PIN you set with
#    'ykman fido access change-pin' — make sure all three keys have a PIN
#    set or the high-friction stacks will refuse them.
PAM_U2F_TOUCH='auth sufficient pam_u2f.so cue'
PAM_U2F_PIN_TOUCH='auth sufficient pam_u2f.so cue pinverification=1'

# /etc/pam.d/kde isn't shipped as a config file by Debian's KDE packages; the
# canonical version lives at /usr/lib/pam.d/kde and is read directly unless a
# local override exists. Copy it into /etc/pam.d so our edits survive package
# updates and so kscreenlocker actually picks them up.
ensure_kde_pam_file() {
    if [ -f /etc/pam.d/kde ]; then
        return 0
    fi
    if [ ! -f /usr/lib/pam.d/kde ]; then
        warn "/usr/lib/pam.d/kde not found — kscreenlocker may not be installed; skipping kde PAM"
        return 1
    fi
    log "Copying /usr/lib/pam.d/kde -> /etc/pam.d/kde (local override)"
    sudo cp /usr/lib/pam.d/kde /etc/pam.d/kde
}

# Insert (or update) a pam_u2f.so line in a PAM file. Idempotent across
# changes to the pam_u2f options: if a pam_u2f line is already there but
# differs from the target, we replace it in place rather than skipping —
# otherwise the script can't roll out new flags like pinverification=1.
add_pam_u2f() {
    local pam_file="$1"
    local pam_line="$2"

    if [ ! -f "$pam_file" ]; then
        skip "$pam_file does not exist — skipping"
        return 0
    fi

    if grep -qF "$pam_line" "$pam_file"; then
        skip "pam_u2f.so already configured correctly in $pam_file"
        return 0
    fi

    if grep -q "pam_u2f.so" "$pam_file"; then
        log "Updating pam_u2f line in $pam_file"
        # Replace the (single) existing pam_u2f line with the new one. The
        # target line contains no sed metacharacters in our usage, but use
        # a delimiter unlikely to clash and escape & for safety.
        local replacement; replacement=${pam_line//&/\\&}
        sudo sed -i "s|^.*pam_u2f.so.*|${replacement}|" "$pam_file"
        if ! grep -qF "$pam_line" "$pam_file"; then
            err "Failed to update pam_u2f line in $pam_file"
            return 1
        fi
        ok "Updated $pam_file"
        return 0
    fi

    # First-time insertion: anchor before the common-auth include. Debian
    # uses '@include common-auth' for sudo/sddm; KDE's stock kde file uses
    # 'auth include common-auth' (no @). Match either.
    local anchor_re
    if grep -qE '^@include[[:space:]]+common-auth' "$pam_file"; then
        anchor_re='^@include[[:space:]]+common-auth'
    elif grep -qE '^auth[[:space:]]+include[[:space:]]+common-auth' "$pam_file"; then
        anchor_re='^auth[[:space:]]+include[[:space:]]+common-auth'
    else
        err "$pam_file has no common-auth anchor — refusing to inject pam_u2f blindly"
        return 1
    fi

    log "Adding pam_u2f.so to $pam_file"
    sudo sed -i -E "/${anchor_re}/i ${pam_line}" "$pam_file"
    if ! grep -qF "$pam_line" "$pam_file"; then
        err "sed completed but $pam_file does not contain the pam_u2f line — investigate before re-running"
        return 1
    fi
    ok "Added to $pam_file"
}

add_pam_u2f /etc/pam.d/sudo "$PAM_U2F_TOUCH"

# Skip pam_u2f for sudo when invoked from an SSH session — the local YubiKey
# isn't reachable from a remote shell, and pam_u2f would otherwise sit there
# waiting for a touch that will never come. Only sudo needs this; sddm and
# the lock screen are always local.
SSH_SKIP_LINE='auth [success=1 default=ignore] pam_succeed_if.so quiet rhost != ""'
if [ -f /etc/pam.d/sudo ] \
   && grep -q '^auth sufficient pam_u2f.so' /etc/pam.d/sudo \
   && ! grep -qF 'pam_succeed_if.so quiet rhost' /etc/pam.d/sudo; then
    log "Adding SSH-session skip for pam_u2f in /etc/pam.d/sudo"
    sudo sed -i "/^auth sufficient pam_u2f.so/i ${SSH_SKIP_LINE}" /etc/pam.d/sudo
    if ! grep -qF "$SSH_SKIP_LINE" /etc/pam.d/sudo; then
        err "Failed to insert SSH-session skip line into /etc/pam.d/sudo"
        exit 1
    fi
    ok "SSH-session skip added to /etc/pam.d/sudo"
fi

add_pam_u2f /etc/pam.d/sddm "$PAM_U2F_PIN_TOUCH"

# KDE lock screen (kscreenlocker_greet) — needs a local override seeded first.
if ensure_kde_pam_file; then
    add_pam_u2f /etc/pam.d/kde "$PAM_U2F_PIN_TOUCH"
fi

warn "Test sudo in a NEW terminal AND lock the screen with Ctrl+Alt+L before"
warn "logging out — if PAM is broken you want to find out while you still"
warn "have a working session."
ok "YubiKey PAM configuration complete"
