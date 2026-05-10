#!/usr/bin/env bash
# run-all.sh — Runs all numbered scripts in order. 00-bootstrap.sh is skipped
# because it must already have been run for this repo to be on disk.
#
# Per-script output is teed into ~/linux-bootstrap-logs/<script>.log so a
# failure leaves a trail you can read after the fact.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
require_sudo

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

for script in "$DIR"/[1-9][0-9]-*.sh; do
    name=$(basename "$script")
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
echo "  All done. Log out and back in to pick up groups, locale and shell."
echo "=========================================================================="
