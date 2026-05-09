#!/usr/bin/env bash
# run-all.sh — Runs all numbered scripts in order. 00-bootstrap.sh is skipped
# because it must already have been run for this repo to be on disk.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for script in "$DIR"/[1-9][0-9]-*.sh; do
    echo
    echo "=========================================================================="
    echo "  $(basename "$script")"
    echo "=========================================================================="
    bash "$script"
done

echo
echo "=========================================================================="
echo "  All done. Log out and back in to pick up groups, locale and shell."
echo "=========================================================================="
