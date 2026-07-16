#!/usr/bin/env bash
# 80-unattended-upgrades.sh — Server-only. Enables automatic upgrades via
# the distribution's unattended-upgrades package.
#
# Policy: EVERYTHING (security + stable-updates + main archive), no
# automatic reboot. Anything that needs a kernel/libc restart waits for
# a human — servers here are stateful enough that a surprise reboot is
# worse than a delayed patch. Use `needrestart -r a` or a scheduled
# reboot from Ansible for that.
#
# Origins covered:
#   Debian: -security + main archive (label=Debian) + -updates
#   Ubuntu: main + -security + -updates + ESM (Apps + Infra)
# Not covered (opinionated skip): -proposed, -backports — those risk
# pulling in in-flight or opt-in packages. Enable them explicitly if
# you want.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user

if is_desktop; then
    skip "Desktop profile — skipping unattended-upgrades"
    exit 0
fi

if is_smoke_test; then
    skip "Smoke test mode — skipping unattended-upgrades (no systemd timers in container)"
    exit 0
fi

require_sudo

if ! apt_installed unattended-upgrades; then
    err "unattended-upgrades not installed. Run 10-packages.sh first."
    exit 1
fi

# 1. Enable the apt-daily timers. This is what dpkg-reconfigure -plow
#    unattended-upgrades would write. Writing it directly keeps the script
#    non-interactive and idempotent. Debian's default file is created only
#    after dpkg-reconfigure runs; on a fresh install it may not exist.
AUTO_UPGRADES=/etc/apt/apt.conf.d/20auto-upgrades
AUTO_UPGRADES_BODY='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
'

current=""
if sudo test -f "$AUTO_UPGRADES"; then
    current=$(sudo cat "$AUTO_UPGRADES")
fi
if [ "$current" = "$AUTO_UPGRADES_BODY" ]; then
    skip "$AUTO_UPGRADES already up to date"
else
    log "Writing $AUTO_UPGRADES"
    printf '%s' "$AUTO_UPGRADES_BODY" | sudo tee "$AUTO_UPGRADES" > /dev/null
    sudo chmod 0644 "$AUTO_UPGRADES"
fi

# 2. Override just the policy bits we care about — don't rewrite the whole
#    50unattended-upgrades file (that's the distro's per-release list of
#    allowed origins and we don't want to fight it). Late alphabetical
#    filename (99-) so our values win.
POLICY=/etc/apt/apt.conf.d/99-bootstrap-unattended.conf
POLICY_BODY='// Written by linux-bootstrap 80-unattended-upgrades.sh
// Overrides selected keys in /etc/apt/apt.conf.d/50unattended-upgrades.
// The distro-shipped 50unattended-upgrades only enables -security by
// default; we replace Origins-Pattern here to cover everything.
//
// All entries use the fully-qualified "origin=X,codename=Y[,label=Z]"
// form. The shorthand "X:Y" (used in Ubuntus defaults) is an
// Ubuntu-only parser extension — Debians unattended-upgrade throws a
// ValueError on it (splits on "," then expects key=value per piece).
// ${distro_codename} substitutes to trixie/noble/jammy at runtime;
// patterns that dont match the current suites are silently ignored.

Unattended-Upgrade::Origins-Pattern {
    // Debian archive: main + point releases (label=Debian) and security.
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates";

    // Ubuntu archive: main + security + bug-fix updates. Harmless
    // no-match on Debian (no repo with origin=Ubuntu).
    "origin=Ubuntu,codename=${distro_codename}";
    "origin=Ubuntu,codename=${distro_codename}-security";
    "origin=Ubuntu,codename=${distro_codename}-updates";
    // Ubuntu Extended Security Maintenance (harmless if not subscribed).
    "origin=UbuntuESMApps,codename=${distro_codename}-apps-security";
    "origin=UbuntuESM,codename=${distro_codename}-infra-security";

    // Deliberately NOT included: -proposed, -backports.
};

// Never reboot automatically. Delayed patch is better than surprise reboot
// on a stateful server; humans (or Ansible) handle reboots explicitly.
Unattended-Upgrade::Automatic-Reboot "false";

// No mail notifications; use journalctl -u unattended-upgrades.service if
// you want to see what ran.
Unattended-Upgrade::Mail "";

// Drop packages that lose /var/cache/apt space over time.
Unattended-Upgrade::Remove-Unused-Dependencies "true";
'

current=""
if sudo test -f "$POLICY"; then
    current=$(sudo cat "$POLICY")
fi
if [ "$current" = "$POLICY_BODY" ]; then
    skip "$POLICY already up to date"
else
    log "Writing $POLICY"
    printf '%s' "$POLICY_BODY" | sudo tee "$POLICY" > /dev/null
    sudo chmod 0644 "$POLICY"
fi

# 3. Enable + start the service and its timers. On modern Debian/Ubuntu the
#    apt-daily.timer + apt-daily-upgrade.timer units are what actually
#    invoke unattended-upgrade; enabling unattended-upgrades.service picks
#    up the boot-time-fired path too.
for unit in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        skip "$unit already enabled"
    else
        log "Enabling $unit"
        sudo systemctl enable "$unit"
    fi
done

# 4. Dry-run the config so a mistake surfaces here instead of at 06:00 tomorrow.
log "Validating unattended-upgrades config (dry-run)"
if ! sudo unattended-upgrade --dry-run --debug > /tmp/unattended-upgrades-dryrun.log 2>&1; then
    err "unattended-upgrade --dry-run failed. See /tmp/unattended-upgrades-dryrun.log"
    exit 1
fi
ok "Config valid (last 3 lines):"
tail -n 3 /tmp/unattended-upgrades-dryrun.log | sed 's/^/    /'

ok "unattended-upgrades configured (all updates, no auto-reboot)"
