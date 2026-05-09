#!/usr/bin/env bash
# 20-locale.sh — Sets sv_SE.UTF-8 as the format locale, keeps en_US.UTF-8 as
# the language. Also disables SSH AcceptEnv so that incoming SSH sessions do
# not carry over locale variables from the client.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
require_sudo

# 1. Enable sv_SE.UTF-8 and en_US.UTF-8 in /etc/locale.gen, comment out
#    en_SE (which does not exist as a real locale).
log "Configuring /etc/locale.gen"
needs_locale_gen=0

ensure_uncommented() {
    local locale_line="$1"
    if grep -qE "^#\s*${locale_line}\b" /etc/locale.gen; then
        sudo sed -i "s|^#\s*\(${locale_line}\)|\1|" /etc/locale.gen
        log "Uncommented $locale_line"
        needs_locale_gen=1
    elif grep -qE "^${locale_line}\b" /etc/locale.gen; then
        skip "$locale_line already enabled"
    else
        warn "Did not find a line for $locale_line in /etc/locale.gen"
    fi
}

ensure_commented() {
    local locale_line="$1"
    if grep -qE "^${locale_line}\b" /etc/locale.gen; then
        sudo sed -i "s|^\(${locale_line}\)|# \1|" /etc/locale.gen
        log "Commented out $locale_line"
        needs_locale_gen=1
    else
        skip "$locale_line already disabled"
    fi
}

ensure_uncommented "sv_SE.UTF-8 UTF-8"
ensure_uncommented "en_US.UTF-8 UTF-8"
ensure_commented   "en_SE.UTF-8 UTF-8"

if [ "$needs_locale_gen" -eq 1 ]; then
    log "Running locale-gen"
    sudo locale-gen
    ok "locale-gen complete"
fi

# 2. Set the system locale: language en_US, formats sv_SE.
log "Setting system locale (LANG=en_US.UTF-8, LC_*=sv_SE.UTF-8)"
sudo localectl set-locale \
    LANG=en_US.UTF-8 \
    LC_TIME=sv_SE.UTF-8 \
    LC_NUMERIC=sv_SE.UTF-8 \
    LC_MONETARY=sv_SE.UTF-8 \
    LC_PAPER=sv_SE.UTF-8 \
    LC_MEASUREMENT=sv_SE.UTF-8 \
    LC_ADDRESS=sv_SE.UTF-8 \
    LC_TELEPHONE=sv_SE.UTF-8 \
    LC_NAME=sv_SE.UTF-8 \
    LC_IDENTIFICATION=sv_SE.UTF-8

# 3. KDE plasma-localerc — use sv_SE.UTF-8 as format source.
PLASMA_LOCALE="$HOME/.config/plasma-localerc"
log "Configuring $PLASMA_LOCALE"
mkdir -p "$(dirname "$PLASMA_LOCALE")"
cat > "$PLASMA_LOCALE" <<'EOF'
[Formats]
LANG=en_US.UTF-8
LC_TIME=sv_SE.UTF-8
LC_NUMERIC=sv_SE.UTF-8
LC_MONETARY=sv_SE.UTF-8
LC_MEASUREMENT=sv_SE.UTF-8
LC_PAPER=sv_SE.UTF-8

[Translations]
LANGUAGE=en_US
EOF
ok "plasma-localerc written"

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

ok "Locale configuration complete. Log out and back in for full effect."
