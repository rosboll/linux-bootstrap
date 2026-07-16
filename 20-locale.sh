#!/usr/bin/env bash
# 20-locale.sh — Sets en_GB.UTF-8 as the language locale, sv_SE.UTF-8 as the
# format locale (ISO dates, 24h clock, metric), and TIME_STYLE=long-iso so
# that ls -l shows YYYY-MM-DD timestamps instead of Swedish month names.
# Also disables SSH AcceptEnv so that incoming SSH sessions do not carry over
# locale variables from the client.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
require_sudo

# 1. Enable sv_SE.UTF-8 and en_GB.UTF-8 in /etc/locale.gen, comment out
#    en_SE (which does not exist as a real locale).
log "Configuring /etc/locale.gen"
needs_locale_gen=0

# Escape regex metacharacters (mostly the dots in 'sv_SE.UTF-8') for grep/sed.
escape_regex() {
    # shellcheck disable=SC2016  # sed expression intentionally literal
    printf '%s' "$1" | sed -e 's/[.[\*^$()+?{|]/\\&/g'
}

ensure_uncommented() {
    local locale_line="$1"
    local re; re=$(escape_regex "$locale_line")
    if grep -qE "^${re}([[:space:]]|$)" /etc/locale.gen; then
        skip "$locale_line already enabled"
    elif grep -qE "^#[[:space:]]*${re}([[:space:]]|$)" /etc/locale.gen; then
        sudo sed -i -E "s|^#[[:space:]]*(${re})|\\1|" /etc/locale.gen
        log "Uncommented $locale_line"
        needs_locale_gen=1
    else
        warn "Did not find a line for $locale_line in /etc/locale.gen"
    fi
}

ensure_commented() {
    local locale_line="$1"
    local re; re=$(escape_regex "$locale_line")
    if grep -qE "^${re}([[:space:]]|$)" /etc/locale.gen; then
        sudo sed -i -E "s|^(${re})|# \\1|" /etc/locale.gen
        log "Commented out $locale_line"
        needs_locale_gen=1
    else
        skip "$locale_line already disabled"
    fi
}

ensure_uncommented "sv_SE.UTF-8 UTF-8"
ensure_uncommented "en_GB.UTF-8 UTF-8"
ensure_commented   "en_SE.UTF-8 UTF-8"

if [ "$needs_locale_gen" -eq 1 ]; then
    log "Running locale-gen"
    sudo locale-gen
    ok "locale-gen complete"
fi

# 2. Set the system locale: language en_US, formats sv_SE.
#    Debian ships a dbus policy that blocks 'localectl set-locale' even as
#    root, expecting you to use 'update-locale' instead (which writes to
#    /etc/default/locale, the Debian source of truth). See Debian bug 1108144.
log "Setting system locale (LANG=en_GB.UTF-8, LC_*=sv_SE.UTF-8)"
sudo update-locale \
    LANG=en_GB.UTF-8 \
    LC_TIME=sv_SE.UTF-8 \
    LC_NUMERIC=sv_SE.UTF-8 \
    LC_MONETARY=sv_SE.UTF-8 \
    LC_PAPER=sv_SE.UTF-8 \
    LC_MEASUREMENT=sv_SE.UTF-8 \
    LC_ADDRESS=sv_SE.UTF-8 \
    LC_TELEPHONE=sv_SE.UTF-8 \
    LC_NAME=sv_SE.UTF-8 \
    LC_IDENTIFICATION=sv_SE.UTF-8

# 3. KDE plasma-localerc — desktop-only. Server profile has no Plasma to
#    read this file, so skip. Only write when the file is missing or differs,
#    so KDE Settings UI tweaks aren't clobbered on every run.
if is_desktop; then
    PLASMA_LOCALE="$HOME/.config/plasma-localerc"
    mkdir -p "$(dirname "$PLASMA_LOCALE")"
    plasma_tmp=$(mktemp)
    cat > "$plasma_tmp" <<'EOF'
[Formats]
LANG=en_GB.UTF-8
LC_TIME=sv_SE.UTF-8
LC_NUMERIC=sv_SE.UTF-8
LC_MONETARY=sv_SE.UTF-8
LC_MEASUREMENT=sv_SE.UTF-8
LC_PAPER=sv_SE.UTF-8

[Translations]
LANGUAGE=en_GB
EOF

    if [ -f "$PLASMA_LOCALE" ] && cmp -s "$plasma_tmp" "$PLASMA_LOCALE"; then
        skip "plasma-localerc already up to date"
        rm -f "$plasma_tmp"
    else
        log "Writing $PLASMA_LOCALE"
        mv "$plasma_tmp" "$PLASMA_LOCALE"
        ok "plasma-localerc written"
    fi
else
    skip "Server profile — no plasma-localerc"
fi

# 4. Disable SSH locale forwarding on the server side. This stops incoming
#    SSH sessions from dragging unwanted locale variables from the client.
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    if grep -qE "^\s*AcceptEnv\s+LANG\s+LC_\*" "$SSHD_CONFIG"; then
        log "Commenting out AcceptEnv in $SSHD_CONFIG"
        sudo sed -i 's|^\(\s*AcceptEnv\s\+LANG\s\+LC_\*\)|# \1|' "$SSHD_CONFIG"
        sudo systemctl reload ssh 2>/dev/null \
            || sudo systemctl reload sshd 2>/dev/null \
            || true
        ok "AcceptEnv disabled"
    else
        skip "AcceptEnv already disabled or not present"
    fi
else
    skip "sshd not installed — skipping AcceptEnv"
fi

# 5. Set TIME_STYLE=long-iso in /etc/environment so that ls -l shows
#    ISO timestamps (2026-01-15 14:30) instead of Swedish month abbreviations.
#    LC_TIME=sv_SE gives ISO date format and 24h clock for date/cal/etc.,
#    but ls uses abbreviated month names by default, which would be Swedish.
ENV_FILE="/etc/environment"
if grep -qE "^TIME_STYLE=" "$ENV_FILE" 2>/dev/null; then
    current_ts=$(grep -E "^TIME_STYLE=" "$ENV_FILE" | cut -d= -f2-)
    if [ "$current_ts" = "long-iso" ]; then
        skip "TIME_STYLE=long-iso already set in $ENV_FILE"
    else
        log "Updating TIME_STYLE in $ENV_FILE (was: $current_ts)"
        sudo sed -i "s|^TIME_STYLE=.*|TIME_STYLE=long-iso|" "$ENV_FILE"
        ok "TIME_STYLE updated to long-iso"
    fi
else
    log "Adding TIME_STYLE=long-iso to $ENV_FILE"
    printf 'TIME_STYLE=long-iso\n' | sudo tee -a "$ENV_FILE" > /dev/null
    ok "TIME_STYLE=long-iso added to $ENV_FILE"
fi

ok "Locale configuration complete. Log out and back in for full effect."
