#!/usr/bin/env bash
# 00-bootstrap.sh — Generates an SSH key, asks you to add it to GitHub, and
# clones the linux-bootstrap repo. This is the only script that lives outside
# the repo from the start — it is meant to be run directly from a GitHub raw
# URL on a fresh machine.
set -euo pipefail

BOOTSTRAP_REPO="git@github.com:rosboll/linux-bootstrap.git"
BOOTSTRAP_DIR="$HOME/linux-bootstrap"
SSH_KEY="$HOME/.ssh/id_ed25519"

# Inline colours (cannot source common.sh — repo is not cloned yet)
if [ -t 1 ]; then
    BLUE=$'\033[0;34m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    RED=$'\033[0;31m'; NC=$'\033[0m'
else
    BLUE=""; GREEN=""; YELLOW=""; RED=""; NC=""
fi
log()  { printf "%s[*]%s %s\n" "$BLUE"   "$NC" "$1"; }
ok()   { printf "%s[+]%s %s\n" "$GREEN"  "$NC" "$1"; }
warn() { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$1"; }
err()  { printf "%s[-]%s %s\n" "$RED"    "$NC" "$1" >&2; }

# Refuse to run as root
if [ "$(id -u)" -eq 0 ]; then
    err "Do not run as root. Run as your normal user."
    exit 1
fi

# 1. SSH key
if [ -f "$SSH_KEY" ]; then
    ok "SSH key already exists: $SSH_KEY"
else
    log "Generating SSH key (ed25519)"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "$USER@$(hostname)" -f "$SSH_KEY" -N ""
    ok "SSH key generated"
fi

# 2. Show public key and pause
echo
echo "==========================================================================="
echo "Add the following public key to GitHub:"
echo "  https://github.com/settings/keys"
echo "==========================================================================="
cat "${SSH_KEY}.pub"
echo "==========================================================================="
echo
read -r -p "Press Enter once the key has been added on GitHub... "

# 3. Verify GitHub accepts the key. GitHub returns exit 1 even for successful
#    auth (no shell granted), so we capture output and grep it instead of
#    piping — under `set -o pipefail`, ssh's exit 1 would otherwise propagate
#    through the pipeline and the success branch would never be taken.
log "Verifying SSH connection to GitHub"
ssh_output=$(ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if printf '%s\n' "$ssh_output" | grep -q "successfully authenticated"; then
    ok "GitHub connection verified"
else
    err "GitHub connection failed. Did you add the key?"
    printf '%s\n' "$ssh_output" >&2
    exit 1
fi

# 4. Clone the bootstrap repo
if [ -d "$BOOTSTRAP_DIR/.git" ]; then
    ok "linux-bootstrap already cloned: $BOOTSTRAP_DIR"
else
    log "Cloning linux-bootstrap to $BOOTSTRAP_DIR"
    git clone "$BOOTSTRAP_REPO" "$BOOTSTRAP_DIR"
    ok "linux-bootstrap cloned"
fi

echo
ok "Bootstrap done. Continue with:"
echo "  cd $BOOTSTRAP_DIR"
echo "  ./run-all.sh    # or run scripts one by one: 10-, 20-, 30-..."
