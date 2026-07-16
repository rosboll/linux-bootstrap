#!/usr/bin/env bash
# run-all.sh — Runs the numbered scripts in order. 00-bootstrap.sh is skipped
# because it must already have been run for this repo to be on disk.
#
# Profiles:
#   (default)   Desktop:  1x, 2x, 3x, 4x, 5x           (YubiKey PAM included)
#   --server    Server:   1x, 2x, 3x, 4x, 7x, 8x, 85   (SSH hardening, etc.)
#
# Pentest tools (6x) are opt-in on either profile via --pentest.
#
# Examples:
#   ./run-all.sh                      desktop base
#   ./run-all.sh --pentest            desktop + pentest tools
#   ./run-all.sh --server             server base
#   ./run-all.sh --server --pentest   e.g. a pentest VM in OCI
#
# Per-script output is teed into ~/linux-bootstrap-logs/<script>.log so a
# failure leaves a trail you can read after the fact.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

pentest=0
profile=desktop
for arg in "$@"; do
    case "$arg" in
        --pentest) pentest=1 ;;
        --server)  profile=server ;;
        --desktop) profile=desktop ;;
        *) err "Unknown argument: $arg"
           echo "Usage: $0 [--server|--desktop] [--pentest]" >&2
           exit 1 ;;
    esac
done
export BOOTSTRAP_PROFILE="$profile"

require_normal_user
require_sudo

pentest_label="off"
[ "$pentest" -eq 1 ] && pentest_label="on"
log "Profile: $profile   Pentest: $pentest_label"

# Background sudo keepalive — refreshes the timestamp every 60s so long-running
# scripts (e.g. cargo install rusthound-ce) don't lose sudo halfway through.
( while true; do
      sudo -nv > /dev/null 2>&1 || exit 0
      sleep 60
  done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

LOG_DIR="$HOME/linux-bootstrap-logs"
mkdir -p "$LOG_DIR"
log "Logs: $LOG_DIR"

# Script selection rules by numeric prefix. Returns 0 if the script should
# run under the current flag combination, non-zero otherwise.
#   5x  YubiKey PAM       → desktop only
#   6x  pentest tools     → opt-in via --pentest (either profile)
#   7x, 8x, 9x  server tail → server only
should_run() {
    case "$1" in
        5*.sh)              [ "$profile" = "desktop" ] ;;
        6*.sh)              [ "$pentest" -eq 1 ] ;;
        7*.sh|8*.sh|9*.sh)  [ "$profile" = "server" ] ;;
        *)                  return 0 ;;
    esac
}

for script in "$DIR"/[1-9][0-9]-*.sh; do
    name=$(basename "$script")
    if ! should_run "$name"; then
        skip "$name — skipped for profile=$profile pentest=$pentest_label"
        continue
    fi
    log_file="$LOG_DIR/${name%.sh}-$(date +%Y%m%d-%H%M%S).log"
    echo
    echo "=========================================================================="
    echo "  $name  (log: $log_file)"
    echo "=========================================================================="
    if ! bash "$script" 2>&1 | tee "$log_file"; then
        err "$name failed. See $log_file"
        exit 1
    fi
done

echo
echo "=========================================================================="
if [ "$profile" = "server" ]; then
    echo "  All done. On a server that had password auth active, verify SSH key"
    echo "  auth in a NEW session before disconnecting the current one."
else
    echo "  All done. Log out and back in to pick up groups, locale and shell."
fi
echo "=========================================================================="
