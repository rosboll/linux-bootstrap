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

# Resolve the dotfiles checkout location. Precedence:
#   1. $DOTFILES_DIR env var (explicit override)
#   2. A sibling of this repo — works when linux-bootstrap is under
#      ~/repos/, ~/code/, ~/work/, etc., and the dotfiles checkout sits
#      next to it.
#   3. $HOME/dotfiles — the simple "everything in $HOME" layout.
# The first existing .git/ checkout wins. If none exist we fall back to
# $HOME/dotfiles and let the script clone there.
if [ -z "${DOTFILES_DIR:-}" ]; then
    sibling="$(dirname "$DIR")/dotfiles"
    if [ -d "$sibling/.git" ]; then
        DOTFILES_DIR="$sibling"
    elif [ -d "$HOME/dotfiles/.git" ]; then
        DOTFILES_DIR="$HOME/dotfiles"
    else
        # Neither exists yet — clone next to linux-bootstrap (sibling layout).
        DOTFILES_DIR="$sibling"
    fi
fi
log "Using dotfiles checkout: $DOTFILES_DIR"

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
    # Move pre-existing real files aside so stow can take over their slot.
    # Source of truth is stow's own dry-run output (`--no`): we ask stow
    # what would conflict, move each conflicting file to ~/original-<name>,
    # and loop until stow reports a clean run. Two passes are usually
    # enough; cap at 4 to avoid an infinite loop if stow ever reports the
    # same conflict on a path we couldn't move.
    move_aside() {
        local rel="$1"
        local target_root="$2"
        local home_target="$target_root/$rel"
        if [ -e "$home_target" ] && [ ! -L "$home_target" ]; then
            local flat
            flat=$(printf '%s' "$rel" | tr '/' '_')
            local backup="$target_root/original-${flat#.}"
            log "Moving $home_target -> $backup"
            if [ "$target_root" = "$HOME" ]; then
                mv "$home_target" "$backup"
            else
                sudo mv "$home_target" "$backup"
            fi
        fi
    }

    resolve_stow_conflicts() {
        local target_root="$1"
        local stow_cmd=("stow" "-n" "--target=$target_root" ".")
        [ "$target_root" != "$HOME" ] && stow_cmd=("sudo" "${stow_cmd[@]}")

        local pass stow_output conflicts
        for pass in 1 2 3 4; do
            # stow -n exits non-zero when conflicts exist — swallow that
            # under set -e -o pipefail, then parse the warnings from output.
            # Explicit subshell so the `|| true` only catches stow's exit,
            # not a hypothetical cd failure.
            stow_output=$( (cd "$DOTFILES_DIR" && "${stow_cmd[@]}") 2>&1 || true)
            conflicts=$(printf '%s\n' "$stow_output" \
                | awk '/existing target is (not owned by stow|neither a link nor a directory)/ { print $NF }' \
                | sort -u)
            [ -z "$conflicts" ] && return 0
            log "stow dry-run reported $(printf '%s\n' "$conflicts" | wc -l) conflict(s) in $target_root (pass $pass)"
            while IFS= read -r rel; do
                [ -n "$rel" ] && move_aside "$rel" "$target_root"
            done <<< "$conflicts"
        done
        err "stow conflicts in $target_root persisted after 4 passes:"
        printf '%s\n' "$conflicts" | sed 's/^/    /' >&2
        return 1
    }

    log "Resolving stow conflicts under \$HOME"
    resolve_stow_conflicts "$HOME"

    log "Running stow into \$HOME"
    (cd "$DOTFILES_DIR" && stow --restow --target="$HOME" .)
    ok "Dotfiles stowed into \$HOME"

    # Share the same dotfiles with root so root's zsh has the user's config.
    # Symlinks point back into /home/$USER/dotfiles; root needs read access
    # there (default Debian /home perms allow this — verify if you've locked
    # /home down).
    log "Resolving stow conflicts under /root"
    resolve_stow_conflicts /root

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
unit_changed=0
if [ ! -f "$SSH_AGENT_UNIT" ] || [ "$(cat "$SSH_AGENT_UNIT")" != "$SSH_AGENT_UNIT_BODY" ]; then
    log "Writing ssh-agent user systemd unit"
    printf '%s' "$SSH_AGENT_UNIT_BODY" > "$SSH_AGENT_UNIT"
    unit_changed=1
fi

if is_smoke_test; then
    skip "Smoke test mode — skipping systemctl --user (no session bus in container)"
elif [ "$unit_changed" -eq 1 ]; then
    # Always restart after a body change. `enable --now` is "start if not
    # running" — it does NOT pick up the new ExecStart on an already-running
    # instance, which leaves a stale process bound to the old command line
    # (no -a flag, no socket at the documented path). Explicit restart fixes
    # that and works regardless of prior state.
    systemctl --user daemon-reload
    systemctl --user enable ssh-agent.service
    systemctl --user restart ssh-agent.service
    ok "ssh-agent user unit enabled and (re)started"
elif ! systemctl --user is-active --quiet ssh-agent.service; then
    log "ssh-agent.service not active — starting"
    systemctl --user start ssh-agent.service
    ok "ssh-agent.service started"
else
    skip "ssh-agent user unit already up to date and active"
fi

# shellcheck disable=SC2016
warn "Make sure your .zshrc exports: export SSH_AUTH_SOCK=\"\$XDG_RUNTIME_DIR/ssh-agent.socket\""

# 6. Mask gcr-ssh-agent. Trixie's KDE pulls in gcr 4.x, which ships its own
#    SSH agent as a standalone systemd user service (gcr-ssh-agent.socket).
#    When user systemd activates that socket it also publishes SSH_AUTH_SOCK
#    into the systemd user environment — every graphical-session-launched
#    Konsole then inherits that socket instead of ours. Worse, the gcr agent
#    has no working secret-service backend on a KDE-only box, so `ssh-add`
#    accepts the passphrase and then hangs indefinitely.
#
#    Mask both the .socket and .service so they cannot auto-activate on the
#    next login. Stop them in the current session for good measure.
if is_smoke_test; then
    skip "Smoke test mode — skipping gcr-ssh-agent masking"
elif systemctl --user cat gcr-ssh-agent.socket > /dev/null 2>&1; then
    enabled_state=$(systemctl --user is-enabled gcr-ssh-agent.socket 2>/dev/null || true)
    if [ "$enabled_state" = "masked" ]; then
        skip "gcr-ssh-agent.socket already masked"
    else
        log "Masking gcr-ssh-agent (conflicts with our ssh-agent user unit)"
        systemctl --user mask gcr-ssh-agent.socket gcr-ssh-agent.service
        systemctl --user stop gcr-ssh-agent.socket gcr-ssh-agent.service 2>/dev/null || true
        ok "gcr-ssh-agent masked and stopped"
    fi
else
    skip "gcr-ssh-agent not installed — nothing to mask"
fi

ok "Shell configuration complete"
