#!/usr/bin/env bash
# 85-timezone.sh — Server-only. Sets the system timezone to Europe/Stockholm
# so journal timestamps read naturally alongside our sv_SE.UTF-8 locale.
#
# Workstations already inherit their timezone from the KDE installer
# question and rarely need adjustment; servers (especially cloud images)
# ship as UTC by default.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user

if is_desktop; then
    skip "Desktop profile — leaving timezone alone (KDE installer set it)"
    exit 0
fi

require_sudo

TZ_WANT="Europe/Stockholm"

if ! command -v timedatectl > /dev/null 2>&1; then
    err "timedatectl not found — non-systemd host? Skipping."
    exit 0
fi

# timedatectl show is machine-readable ('Timezone=Europe/Stockholm').
current=$(timedatectl show -p Timezone --value 2>/dev/null || true)
if [ "$current" = "$TZ_WANT" ]; then
    skip "Timezone already $TZ_WANT"
else
    log "Setting timezone: $current -> $TZ_WANT"
    sudo timedatectl set-timezone "$TZ_WANT"
    ok "Timezone set to $TZ_WANT"
fi
