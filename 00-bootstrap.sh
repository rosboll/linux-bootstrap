#!/usr/bin/env bash
# 00-bootstrap.sh — Bootstraps the repo onto a fresh machine.
#
#   (default)  Desktop: generates an SSH key, asks you to add it to GitHub,
#              clones the repo via SSH.
#   --server   Server:  skips SSH key setup, clones via HTTPS anonymously.
#              Suits headless boxes where you don't want a GitHub-linked key
#              (proxmox guests, cloud VMs, etc.).
#
# This is the only script that lives outside the repo from the start — it's
# meant to be run directly from a GitHub raw URL on a fresh machine.
set -euo pipefail

REPO_SSH="git@github.com:rosboll/linux-bootstrap.git"
REPO_HTTPS="https://github.com/rosboll/linux-bootstrap.git"
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

profile=desktop
for arg in "$@"; do
    case "$arg" in
        --server)  profile=server ;;
        --desktop) profile=desktop ;;
        *) err "Unknown argument: $arg"
           echo "Usage: $0 [--server|--desktop]" >&2
           exit 1 ;;
    esac
done

if [ "$profile" = "server" ]; then
    log "Server profile: cloning $REPO_HTTPS anonymously (no GitHub SSH key needed)"

    if ! command -v git > /dev/null 2>&1; then
        err "git is not installed. Install it first:"
        err "    sudo apt update && sudo apt install -y git curl"
        exit 1
    fi

    if [ -d "$BOOTSTRAP_DIR/.git" ]; then
        ok "linux-bootstrap already cloned: $BOOTSTRAP_DIR"
    else
        log "Cloning linux-bootstrap to $BOOTSTRAP_DIR"
        git clone "$REPO_HTTPS" "$BOOTSTRAP_DIR"
        ok "linux-bootstrap cloned"
    fi

    echo
    ok "Bootstrap done. Continue with:"
    echo "  cd $BOOTSTRAP_DIR"
    echo "  ./run-all.sh --server"
    exit 0
fi

# Desktop profile: generate SSH key, add to GitHub, clone via SSH.

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
    git clone "$REPO_SSH" "$BOOTSTRAP_DIR"
    ok "linux-bootstrap cloned"
fi

echo
ok "Bootstrap done. Continue with:"
echo "  cd $BOOTSTRAP_DIR"
echo "  ./run-all.sh    # or run scripts one by one: 10-, 20-, 30-..."
