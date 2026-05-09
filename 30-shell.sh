#!/usr/bin/env bash
# 30-shell.sh — Sets zsh as default shell for $USER and root, clones the
# dotfiles repo if missing, stows it (handling conflicts by moving existing
# rc files to original-*), and creates a user-systemd unit for ssh-agent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

require_normal_user
require_sudo

DOTFILES_REPO="git@github.com:rosboll/dotfiles.git"
DOTFILES_DIR="$HOME/dotfiles"

# 1. zsh as default for $USER
ZSH_PATH=$(command -v zsh || true)
if [ -z "$ZSH_PATH" ]; then
    err "zsh not installed. Run 10-packages.sh first."
    exit 1
fi

current_shell=$(getent passwd "$USER" | cut -d: -f7)
if [ "$current_shell" = "$ZSH_PATH" ]; then
    skip "zsh already default for $USER"
else
    log "Setting zsh as default for $USER"
    sudo chsh -s "$ZSH_PATH" "$USER"
    ok "zsh set for $USER"
fi

# 2. zsh as default for root
root_shell=$(sudo getent passwd root | cut -d: -f7)
if [ "$root_shell" = "$ZSH_PATH" ]; then
    skip "zsh already default for root"
else
    log "Setting zsh as default for root"
    sudo chsh -s "$ZSH_PATH" root
    ok "zsh set for root"
fi

# 3. Clone dotfiles if missing
if [ -d "$DOTFILES_DIR/.git" ]; then
    skip "Dotfiles already cloned: $DOTFILES_DIR"
else
    log "Cloning dotfiles to $DOTFILES_DIR"
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
    ok "Dotfiles cloned"
fi

# 4. Stow dotfiles — move conflicts to original-*
log "Handling potential stow conflicts"
cd "$DOTFILES_DIR"
# List files the dotfiles repo wants to stow (top-level dotfiles, excluding
# repo metadata).
mapfile -t dotfile_targets < <(
    find . -maxdepth 1 -mindepth 1 \
        \( -name '.*' \
           -a ! -name '.git' \
           -a ! -name '.gitignore' \
           -a ! -name '.gitmodules' \
        \) -printf '%f\n'
)

for target in "${dotfile_targets[@]}"; do
    home_target="$HOME/$target"
    # If already a symlink into dotfiles → ok, skip
    if [ -L "$home_target" ] && readlink "$home_target" | grep -q "dotfiles/$target$"; then
        skip "$target already symlinked"
        continue
    fi
    # If a real file/directory exists → move it aside
    if [ -e "$home_target" ] && [ ! -L "$home_target" ]; then
        backup="$HOME/original-${target#.}"
        log "Moving $home_target -> $backup"
        mv "$home_target" "$backup"
    fi
done

log "Running stow"
cd "$DOTFILES_DIR"
stow . -t "$HOME"
ok "Dotfiles stowed"

# 5. ssh-agent as a user systemd unit (so it persists across login sessions)
SSH_AGENT_UNIT="$HOME/.config/systemd/user/ssh-agent.service"
if [ -f "$SSH_AGENT_UNIT" ]; then
    skip "ssh-agent user unit already exists"
else
    log "Creating ssh-agent user systemd unit"
    mkdir -p "$(dirname "$SSH_AGENT_UNIT")"
    cat > "$SSH_AGENT_UNIT" <<'EOF'
[Unit]
Description=SSH key agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now ssh-agent
    ok "ssh-agent user unit enabled"
    warn "Add the following to your .zshrc if it is not already there:"
    # shellcheck disable=SC2016
    echo '    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"'
fi

ok "Shell configuration complete"
