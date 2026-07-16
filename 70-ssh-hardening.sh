#!/usr/bin/env bash
# 70-ssh-hardening.sh — Server-only. Locks down sshd:
#   PasswordAuthentication no
#   PermitRootLogin prohibit-password
#   KbdInteractive off, MaxAuthTries 4, LoginGraceTime 30
#
# Written as a drop-in at /etc/ssh/sshd_config.d/01-bootstrap-hardening.conf
# so the main /etc/ssh/sshd_config stays pristine and package upgrades won't
# clobber our changes. Debian's stock sshd_config has 'Include
# /etc/ssh/sshd_config.d/*.conf' at the top; sshd uses first-value-wins
# semantics so our drop-in overrides the main file's later defaults.
#
# CRITICAL: filename must sort BEFORE any other drop-in that sets the
# same keywords. Ubuntu cloud images (OCI, AWS, GCP) ship
# `50-cloud-init.conf` with `PasswordAuthentication yes` — a
# later-alphabetical name would lose to it and the hardening would
# silently no-op. The `01-` prefix beats the 50-/60-cloudimg files.
#
# Refuses to run if $USER has no authorized_keys — flipping
# PasswordAuthentication=no in that state locks you out.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user

if is_desktop; then
    skip "Desktop profile — skipping SSH hardening"
    exit 0
fi

if is_smoke_test; then
    skip "Smoke test mode — skipping SSH hardening (no live sshd in container)"
    exit 0
fi

require_sudo

# 1. sshd installed?
if ! [ -x /usr/sbin/sshd ]; then
    warn "sshd not installed at /usr/sbin/sshd — nothing to harden."
    warn "Install with: sudo apt install openssh-server"
    exit 0
fi

# 2. Lock-out precheck. Count non-comment non-blank lines in authorized_keys —
#    a proxy for "will key auth work after we disable passwords." We can't
#    verify the private key end from here, so this is the closest we can
#    reasonably get.
count_authorized_keys() {
    local file="$1"
    [ -f "$file" ] || { echo 0; return; }
    awk 'NF && !/^[[:space:]]*#/ {n++} END {print n+0}' "$file"
}

user_keys=$(count_authorized_keys "$HOME/.ssh/authorized_keys")
if [ "$user_keys" -lt 1 ]; then
    err "$USER has no keys in ~/.ssh/authorized_keys."
    err "Disabling PasswordAuthentication now would lock you out."
    err ""
    err "Add your public key first, e.g.:"
    err "    mkdir -p ~/.ssh && chmod 700 ~/.ssh"
    err "    printf 'ssh-ed25519 AAAA... comment\\n' >> ~/.ssh/authorized_keys"
    err "    chmod 600 ~/.ssh/authorized_keys"
    err ""
    err "Then re-run this script. Tip: safest to do from the machine's"
    err "local/serial/hypervisor console, not from the SSH session you"
    err "are hardening."
    exit 1
fi
ok "$user_keys key(s) present in $USER's authorized_keys — precheck OK"

# 3. Clean up the legacy 99-* file from earlier runs of this script.
#    Previous versions used a 99- prefix which loses to Ubuntu cloud
#    images' 50-cloud-init.conf under sshd's first-wins semantics.
LEGACY_HARDENING=/etc/ssh/sshd_config.d/99-bootstrap-hardening.conf
if sudo test -f "$LEGACY_HARDENING"; then
    log "Removing legacy $LEGACY_HARDENING (replaced by 01-* prefix)"
    sudo rm -f "$LEGACY_HARDENING"
fi

# 4. Write the drop-in. Only touch disk when content differs so re-runs
#    stay silent under [=].
HARDENING_FILE=/etc/ssh/sshd_config.d/01-bootstrap-hardening.conf
HARDENING_BODY='# Written by linux-bootstrap 70-ssh-hardening.sh
# Server-profile SSH lockdown. Do not edit; will be overwritten on next run.
# 01- prefix is intentional: sshd_config.d/*.conf uses first-value-wins,
# and Ubuntu cloud images ship 50-cloud-init.conf setting the opposite of
# what we want. Anything else you want to change goes in the main
# /etc/ssh/sshd_config or another drop-in — just make sure its filename
# sorts LATER than this one if it might set the same keywords.
PasswordAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 4
LoginGraceTime 30
'

current=""
if sudo test -f "$HARDENING_FILE"; then
    current=$(sudo cat "$HARDENING_FILE")
fi
if [ "$current" = "$HARDENING_BODY" ]; then
    skip "$HARDENING_FILE already up to date"
    exit 0
fi

log "Writing $HARDENING_FILE"
printf '%s' "$HARDENING_BODY" | sudo tee "$HARDENING_FILE" > /dev/null
sudo chmod 0644 "$HARDENING_FILE"

# 5. Validate before reload. sshd -t exits non-zero on any config parse
#    error. If we ship a broken drop-in and reload anyway, sshd may fail
#    to start on next boot — remove the file if it doesn't parse.
if ! sudo sshd -t; then
    err "sshd -t rejected the new drop-in. Removing $HARDENING_FILE."
    sudo rm -f "$HARDENING_FILE"
    exit 1
fi

# 6. Reload (not restart) so the current session stays up. Debian's unit
#    name is 'ssh'; some distros use 'sshd'. Try both.
log "Reloading sshd"
if sudo systemctl reload ssh 2>/dev/null; then
    ok "ssh reloaded"
elif sudo systemctl reload sshd 2>/dev/null; then
    ok "sshd reloaded"
else
    err "Could not reload ssh/sshd via systemctl."
    exit 1
fi

warn "Test SSH in a NEW session before logging out — if key auth isn't"
warn "working the next login will be denied entirely (no password fallback)."
ok "SSH hardening complete"
