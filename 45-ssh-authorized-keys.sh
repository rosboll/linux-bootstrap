#!/usr/bin/env bash
# 45-ssh-authorized-keys.sh — Imports the public keys published on a GitHub
# account into $USER's ~/.ssh/authorized_keys, so the machine accepts inbound
# SSH from any key already registered on GitHub.
#
# Runs on BOTH profiles. On servers it removes the manual "paste your pubkey
# in before hardening" step that 70-ssh-hardening.sh otherwise demands; on
# workstations it's what lets you SSH *into* the box from your other machines.
#
# Numbering is load-bearing, twice over:
#   - It must sort BEFORE 70-ssh-hardening.sh, which disables password auth
#     and needs authorized_keys populated first.
#   - It must NOT be in the 5x or 6x band. run-all.sh's should_run() maps
#     5* to desktop-only and 6* to --pentest-only, so a 65-* script would be
#     silently skipped on exactly the profile that needs it most. 1x-4x is
#     the band that runs unconditionally.
#
# What this is and isn't:
#   - It is import-only. Deleting a key on GitHub does NOT remove it from
#     machines that already imported it — revocation is a manual edit of
#     ~/.ssh/authorized_keys on each host.
#   - The trust anchor is the GitHub *username*, resolved over TLS at run
#     time. Whatever github.com/<user>.keys serves at that moment gains
#     login as a sudo-capable user.
#
# Failure is deliberately non-fatal: a network blip here shouldn't abort the
# whole bootstrap run. 70-ssh-hardening.sh's own precheck is the backstop —
# it refuses to disable password auth if this left the file empty.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user

# Hardcoded, like rosboll/dotfiles in 30-shell.sh. Override for a one-off
# host with: GITHUB_USER=someone ./45-ssh-authorized-keys.sh
GITHUB_USER="${GITHUB_USER:-rosboll}"
IMPORT_ID="gh:${GITHUB_USER}"
AUTH_KEYS="$HOME/.ssh/authorized_keys"

# Reporting only. Not $USER directly: this script is the one you're most
# likely to run from a non-login shell (`ssh host ./45-...`, a systemd unit),
# where USER can be unset — and under `set -u` that would abort the run after
# the keys were already written, which reads like a failed import.
ME="${USER:-$(id -un)}"

# 1. Tool present? Comes from packages/base.txt, so 10-packages.sh has
#    normally installed it by now. Don't hard-fail if it hasn't.
if ! command -v ssh-import-id > /dev/null 2>&1; then
    warn "ssh-import-id not installed — skipping key import."
    warn "Install with: sudo apt install ssh-import-id, then re-run this script."
    exit 0
fi

# 2. Network precheck, purely for a better error message. getent reflects
#    what ssh-import-id's HTTPS fetch will actually experience.
if ! dns_works; then
    warn "Cannot resolve github.com — skipping key import."
    warn "Re-run this script once the host has working DNS/egress."
    exit 0
fi

# 3. Make sure ~/.ssh exists with sane permissions before anything writes to
#    it. sshd ignores authorized_keys on a group/world-writable path, and a
#    file created later by some other tool inherits whatever it finds here.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$AUTH_KEYS" ]; then
    touch "$AUTH_KEYS"
fi
chmod 600 "$AUTH_KEYS"

before=$(count_authorized_keys "$AUTH_KEYS")

# 4. Import. The gh: prefix is mandatory — a bare username defaults to
#    Launchpad (lp:), which is not what we want and would fail confusingly.
#    ssh-import-id skips keys already present and tags each line it adds
#    with '# ssh-import-id gh:<user>', so re-runs are no-ops and imported
#    keys stay distinguishable from hand-added ones.
log "Importing SSH keys from ${IMPORT_ID}"
if ! import_output=$(ssh-import-id "$IMPORT_ID" 2>&1); then
    warn "ssh-import-id ${IMPORT_ID} failed:"
    printf '%s\n' "$import_output" | sed 's/^/    /' >&2
    warn "Continuing — 70-ssh-hardening.sh will refuse to disable password"
    warn "auth if this left ~/.ssh/authorized_keys empty."
    exit 0
fi

after=$(count_authorized_keys "$AUTH_KEYS")
added=$((after - before))

if [ "$added" -gt 0 ]; then
    ok "Imported $added new key(s) from ${IMPORT_ID}"
else
    skip "No new keys from ${IMPORT_ID} — already up to date"
fi

# 5. Show what the box now accepts. These keys are root-equivalent on a host
#    with passwordless sudo, so print fingerprints rather than a bare count:
#    it's the only cheap way to notice a key you didn't expect.
log "$after key(s) now authorized for ${ME}:"
while IFS= read -r line; do
    # Skip blanks and comments, matching count_authorized_keys' awk NF test
    # so the printed list and the "$after" count can't disagree.
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if fingerprint=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null); then
        printf '    %s\n' "$fingerprint"
    else
        printf '    (unparsable line, left untouched)\n'
    fi
done < "$AUTH_KEYS"

ok "authorized_keys configured"
