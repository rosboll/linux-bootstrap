#!/usr/bin/env bash
# 50-yubikey.sh — Configures PAM so a YubiKey can be used for sudo.
# Key registration (pamu2fcfg) is inherently manual and must be done with each
# physical key plugged in — this script pauses to let you do it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
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

# 4. Add pam_u2f.so to sudo.
#
#    'sufficient' means a YubiKey touch is enough; password still works as fallback.
#    'cue' prints "Please touch the device" instead of waiting silently.
PAM_U2F_TOUCH='auth sufficient pam_u2f.so cue'

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
#
# We do this via pam_exec running a tiny helper script that checks
# $PAM_RHOST (set by sshd when the session is remote). pam_succeed_if's
# string comparator was tempting but unusable here: its argument parser
# doesn't strip quotes, so `rhost != ""` compares to the literal 2-char
# string `""` and always returns true — silently skipping pam_u2f even on
# local sessions.
PAM_HELPER=/usr/local/bin/pam-skip-if-remote
# Helper that drives the SSH-skip in /etc/pam.d/sudo. Walks the process
# tree from $PPID (sudo) upward and exits 0 if any ancestor is sshd or
# sshd-session (openssh PrivSep helper, used by Trixie). Exits 1 if no
# such ancestor is found within 12 hops.
#
# We cannot rely on $PAM_RHOST: sudo creates a fresh PAM context and does
# not propagate RHOST from the parent (sshd) session on Debian, so the
# variable is empty even for SSH-invoked sudo.
#
# Mapping in /etc/pam.d/sudo:
#   auth [success=1 default=ignore] pam_exec.so quiet <this script>
#   auth sufficient                  pam_u2f.so cue
# Exit 0 -> PAM_SUCCESS -> jump 1 line -> skip pam_u2f (remote)
# Exit 1 -> PAM_AUTH_ERR -> default=ignore -> run pam_u2f (local)
# shellcheck disable=SC2016  # $PPID etc. are expanded by /bin/sh, not bash
PAM_HELPER_BODY='#!/bin/sh
pid=$PPID
i=0
while [ "$i" -lt 12 ] && [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || break
    case "$comm" in
        sshd|sshd-session) exit 0 ;;
    esac
    pid=$(awk '"'"'$1=="PPid:"{print $2; exit}'"'"' "/proc/$pid/status" 2>/dev/null)
    i=$((i + 1))
done
exit 1
'

current_helper=""
if [ -f "$PAM_HELPER" ]; then
    current_helper=$(sudo cat "$PAM_HELPER")
fi
if [ "$current_helper" != "$PAM_HELPER_BODY" ]; then
    log "Writing $PAM_HELPER"
    printf '%s' "$PAM_HELPER_BODY" | sudo tee "$PAM_HELPER" > /dev/null
    sudo chmod 0755 "$PAM_HELPER"
fi

# Clean up the legacy (broken) pam_succeed_if guard if it's still in place.
if grep -q 'pam_succeed_if.so quiet rhost' /etc/pam.d/sudo; then
    log "Removing legacy SSH-guard (pam_succeed_if rhost) from /etc/pam.d/sudo"
    sudo sed -i '/pam_succeed_if.so quiet rhost/d' /etc/pam.d/sudo
fi

# Insert the pam_exec gate ahead of the pam_u2f line.
PAM_EXEC_GUARD="auth [success=1 default=ignore] pam_exec.so quiet $PAM_HELPER"
if [ -f /etc/pam.d/sudo ] \
   && grep -q '^auth sufficient pam_u2f.so' /etc/pam.d/sudo \
   && ! grep -qF "pam_exec.so quiet $PAM_HELPER" /etc/pam.d/sudo; then
    log "Adding SSH-session skip for pam_u2f in /etc/pam.d/sudo"
    sudo sed -i "/^auth sufficient pam_u2f.so/i ${PAM_EXEC_GUARD}" /etc/pam.d/sudo
    if ! grep -qF "pam_exec.so quiet $PAM_HELPER" /etc/pam.d/sudo; then
        err "Failed to insert SSH-session skip into /etc/pam.d/sudo"
        exit 1
    fi
    ok "SSH-session skip added to /etc/pam.d/sudo"
fi

# Remove pam_u2f from SDDM and KDE — YubiKey is not used for login/lock.
# This is a cleanup step so re-running undoes any previously applied config.
remove_pam_u2f() {
    local pam_file="$1"
    if [ -f "$pam_file" ] && grep -q "pam_u2f.so" "$pam_file"; then
        log "Removing pam_u2f.so from $pam_file"
        sudo sed -i '/pam_u2f.so/d' "$pam_file"
        ok "Removed pam_u2f from $pam_file"
    else
        skip "pam_u2f.so not present in $pam_file — nothing to remove"
    fi
}

remove_pam_u2f /etc/pam.d/sddm
remove_pam_u2f /etc/pam.d/kde

warn "Test sudo in a NEW terminal before logging out — if PAM is broken"
warn "you want to find out while you still have a working session."
ok "YubiKey PAM configuration complete"
