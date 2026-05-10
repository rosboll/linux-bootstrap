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

# 3. Clone dotfiles if missing. Skipped in smoke-test mode — the container
#    has no SSH access to GitHub.
if is_smoke_test; then
    skip "Smoke test mode — skipping dotfiles clone and stow"
elif [ -d "$DOTFILES_DIR/.git" ]; then
    skip "Dotfiles already cloned: $DOTFILES_DIR"
else
    log "Cloning dotfiles to $DOTFILES_DIR"
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
    ok "Dotfiles cloned"
fi

# 4. Stow dotfiles. The dotfiles repo uses a FLAT layout: every target file
#    lives at the repo root, intended to be symlinked directly into $HOME.
#    `stow . -t $HOME` works because stow's built-in default-ignore-list
#    skips .git, README.*, LICENSE.* etc.
#
#    Conflict handling: any pre-existing real file under $HOME that the repo
#    wants to own gets moved to ~/original-<name> first.
if ! is_smoke_test; then
    log "Handling potential stow conflicts"
    cd "$DOTFILES_DIR"

    # Walk every file the dotfiles repo would symlink into $HOME, ignoring
    # repo metadata. We don't restrict to top-level dotfiles — the repo may
    # also stow files under .config/<tool>/.
    mapfile -t conflict_targets < <(
        find . -mindepth 1 \
            \( -name '.git' -o -name '.gitignore' -o -name '.gitmodules' \
               -o -name 'README*' -o -name 'LICENSE*' -o -name 'COPYING' \
               -o -name '.stow-local-ignore' \) -prune \
            -o -type f -printf '%P\n' \
            -o -type l -printf '%P\n'
    )

    for rel in "${conflict_targets[@]}"; do
        home_target="$HOME/$rel"
        src="$DOTFILES_DIR/$rel"

        # If already a symlink that resolves to the dotfiles file → fine.
        if [ -L "$home_target" ] && [ "$(readlink -f "$home_target" 2>/dev/null)" = "$src" ]; then
            continue
        fi
        # If a real file/dir is in the way → move it aside (top-level only;
        # nested originals get a flattened name to avoid colliding directories).
        if [ -e "$home_target" ] && [ ! -L "$home_target" ]; then
            backup_name="original-$(echo "$rel" | tr '/' '_')"
            backup_name="${backup_name#original-.}"
            log "Moving $home_target -> $HOME/original-${backup_name}"
            mv "$home_target" "$HOME/original-${backup_name}"
        fi
    done

    log "Running stow into \$HOME"
    (cd "$DOTFILES_DIR" && stow --restow --target="$HOME" .)
    ok "Dotfiles stowed into \$HOME"

    # Share the same dotfiles with root so root's zsh has the user's config.
    # Symlinks point back into /home/$USER/dotfiles; root needs read access
    # there (default Debian /home perms allow this — verify if you've locked
    # /home down).
    log "Stowing the same dotfiles into /root"
    (cd "$DOTFILES_DIR" && sudo stow --restow --target=/root .)
    ok "Dotfiles stowed into /root (symlinks into $DOTFILES_DIR)"
fi

# 5. ssh-agent as a user systemd unit (so it persists across login sessions).
#    ExecStartPre cleans up a stale socket — without it, restarts fail.
SSH_AGENT_UNIT="$HOME/.config/systemd/user/ssh-agent.service"
# shellcheck disable=SC2016  # $SSH_AUTH_SOCK is expanded by systemd, not bash
SSH_AGENT_UNIT_BODY='[Unit]
Description=SSH key agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStartPre=-/bin/rm -f %t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK

[Install]
WantedBy=default.target
'
mkdir -p "$(dirname "$SSH_AGENT_UNIT")"
if [ -f "$SSH_AGENT_UNIT" ] && [ "$(cat "$SSH_AGENT_UNIT")" = "$SSH_AGENT_UNIT_BODY" ]; then
    skip "ssh-agent user unit already up to date"
else
    log "Writing ssh-agent user systemd unit"
    printf '%s' "$SSH_AGENT_UNIT_BODY" > "$SSH_AGENT_UNIT"
    if is_smoke_test; then
        skip "Smoke test mode — skipping systemctl --user (no session bus in container)"
    else
        systemctl --user daemon-reload
        systemctl --user enable --now ssh-agent
        ok "ssh-agent user unit enabled"
    fi
    warn "Make sure your .zshrc exports SSH_AUTH_SOCK if it does not already:"
    # shellcheck disable=SC2016
    echo '    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"'
fi

ok "Shell configuration complete"
