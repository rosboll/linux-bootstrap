# linux-bootstrap

> **Personal setup, published as-is.** This repo bootstraps *my*
> Debian/Ubuntu machines. It hardcodes Swedish locale (`sv_SE.UTF-8`),
> `Europe/Stockholm` timezone, `rosboll/dotfiles` as the dotfiles source,
> and an opinionated package selection. If you're not me, fork it and
> adjust before running. **Read every script before executing** — these
> touch PAM, sshd, and package management as root. Licensed MIT (see
> [LICENSE](LICENSE)), no warranty.

Numbered, idempotent scripts for setting up either:

- a fresh Debian 13 (Trixie) + KDE **workstation** (the default profile), or
- a Debian 13 / Ubuntu LTS **server** (`--server` profile) — no DE, no
  YubiKey, adds SSH lockdown, unattended security upgrades, and timezone.

Scripts are safe to re-run.

The repo only contains setup scripts. Dotfiles live in a separate repo
(`rosboll/dotfiles`) and are cloned and stowed by `30-shell.sh`. If you
fork this, either publish your own dotfiles at a public URL or override
`DOTFILES_DIR` to point at a pre-existing checkout.

> **On running `bash <(curl ...)`**: the two bootstrap one-liners below
> pipe a script from GitHub straight into bash. That's a large trust
> ask — inspect [`00-bootstrap.sh`](00-bootstrap.sh) before running it,
> or `curl` it to disk first and read it. Same goes for every other
> script in this repo.

## Prerequisites

Before running these scripts, Debian must be installed and you must be able to
log in. You also need:

- `git`, `curl`, `sudo` installed
- Your user added to the `sudo` group

If anything is missing:

```bash
su -
apt update && apt install -y git curl sudo
usermod -aG sudo <your-username>
exit
# Log out and back in
```

## Usage

### Desktop (workstation)

```bash
# 1. Bootstrap (generates SSH key, asks you to add it to GitHub,
#    clones this repo via SSH)
bash <(curl -sSL https://raw.githubusercontent.com/rosboll/linux-bootstrap/main/00-bootstrap.sh)

# That clones the repo to ~/linux-bootstrap. Run the rest from there:
cd ~/linux-bootstrap

# 2. Run remaining scripts in order, or all at once via run-all.sh
./10-packages.sh
./20-locale.sh
./30-shell.sh           # also clones rosboll/dotfiles and stows it
./40-services.sh
./50-yubikey.sh
./60-pentest-tools.sh   # optional; run directly if you want pentest tools

# Or everything in one go (after 00-bootstrap):
./run-all.sh                        # desktop base (default)
./run-all.sh --pentest              # desktop + pentest tools
```

### Server (Debian 13 or Ubuntu LTS)

Servers clone **anonymously via HTTPS** — no SSH key needs to be tied
to GitHub. Two equally valid paths:

```bash
# One-liner via 00-bootstrap.sh with --server:
bash <(curl -sSL https://raw.githubusercontent.com/rosboll/linux-bootstrap/main/00-bootstrap.sh) --server
cd ~/linux-bootstrap
./run-all.sh --server               # + --pentest for e.g. OCI pentest VM

# Or clone directly and skip 00-bootstrap.sh entirely:
git clone https://github.com/rosboll/linux-bootstrap.git ~/linux-bootstrap
cd ~/linux-bootstrap
./run-all.sh --server
```

The dotfiles repo (`rosboll/dotfiles`) is also cloned over HTTPS on the
server profile. See the [Server profile](#server-profile) section for
what runs vs. skips, the SSH lockdown precheck, and unattended-upgrades
policy.

`run-all.sh` keeps `sudo` warm in the background and tees per-script output
into `~/linux-bootstrap-logs/`.

## Reusing an existing SSH key (reinstall)

When reinstalling on a machine where the SSH key already exists on a USB
stick, skip `00-bootstrap.sh` entirely and copy the keys in manually before
cloning the repo. KDE automounts USB drives under `/media/$USER/<label>`.

```bash
# Insert the USB stick and let KDE mount it. Confirm the path:
ls /media/$USER/

# Copy the keys (adjust USB label and path as needed)
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cp /media/$USER/<USB-LABEL>/id_ed25519     ~/.ssh/
cp /media/$USER/<USB-LABEL>/id_ed25519.pub ~/.ssh/
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# Verify against GitHub. SSH returns exit 1 even on success (shell access is
# denied), so look for "successfully authenticated" in the output.
ssh -T -o StrictHostKeyChecking=accept-new git@github.com

# Clone this repo directly — skip 00-bootstrap.sh
git clone git@github.com:rosboll/linux-bootstrap.git ~/linux-bootstrap
cd ~/linux-bootstrap
./run-all.sh
```

**Passphrase-protected keys**: if the key on the USB stick has a passphrase
(typically yes), `git pull` and other ssh-using commands will *appear to
hang* after each reboot until the passphrase is loaded into the user
ssh-agent. The agent is started by 30-shell.sh as a systemd user unit, but
nothing loads keys into it automatically. Either:

```bash
# Manual, once per login session:
ssh-add ~/.ssh/id_ed25519
```

…or have your dotfiles do it for you in `~/.zshrc` (we use `.zshrc` rather
than `.zlogin` because KDE Konsole tabs aren't login shells):

```zsh
if [[ -o interactive ]] && [[ -z "${SSH_CONNECTION:-}" ]] \
   && [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    ssh-add -l &>/dev/null
    case $? in
        1) ssh-add "$HOME/.ssh/id_ed25519" ;;
        2) print -u2 "ssh-agent not reachable (SSH_AUTH_SOCK=$SSH_AUTH_SOCK)" ;;
    esac
fi
```

If `ssh -vvv git@github.com` ends with `Enter passphrase for key …` and
hangs, this is what you're hitting. To make a hung run easier to diagnose,
`30-shell.sh` now does a `ssh -o BatchMode=yes` probe before any git
operation and exits with a clear hint instead of silently hanging behind
`tee`.

## Smoke test (container)

The repo includes a `Containerfile` and a `Makefile` that boots Debian 13 in
a container, copies the repo in, and runs `BOOTSTRAP_SMOKE=1 ./run-all.sh
--pentest`. That env var makes scripts skip operations that need credentials
or hardware we don't have inside a container:

- `00-bootstrap.sh` is not invoked at all
- `30-shell.sh` skips dotfiles clone, stow, and `systemctl --user`
- `40-services.sh` skips `docker.service` enable
- `50-yubikey.sh` exits early
- `60-pentest-tools.sh` does the apt prereqs only — no go/cargo/pipx

```bash
make lint    # shellcheck (apt install shellcheck)
make smoke   # full container run; uses podman or docker
```

`make smoke` exits non-zero on any script failure, which makes it suitable
for CI.

## What each script does

| Script                     | Profile        | Description                                                                                | Idempotent |
|----------------------------|----------------|--------------------------------------------------------------------------------------------|------------|
| 00-bootstrap.sh            | both           | SSH key, clone this repo                                                                   | Yes        |
| 10-packages.sh             | both           | apt packages from `packages/base.txt` + `packages/{desktop,server}.txt`; configures VS Code / HashiCorp / gh repos (HashiCorp suite from `/etc/os-release`) | Yes |
| 20-locale.sh               | both           | sv_SE.UTF-8 locale + sshd AcceptEnv + `TIME_STYLE=long-iso`. KDE `plasma-localerc` only on desktop | Yes |
| 30-shell.sh                | both           | zsh as default for $USER and root + clone & stow dotfiles into both + ssh-agent user unit + mask gcr-ssh-agent | Yes |
| 40-services.sh             | both           | docker group. libvirt/kvm/wireshark groups + libvirt default network only on desktop       | Yes        |
| 50-yubikey.sh              | desktop        | libpam-u2f, PAM config for sudo (touch only, skipped over SSH via pam_exec helper)         | Yes        |
| 60-pentest-tools.sh        | opt-in         | nuclei, subfinder, httpx, naabu, ffuf, gobuster, kerbrute, mitmproxy, netexec, responder, sqlmap, nikto, hydra, feroxbuster, semgrep, impacket, certipy-ad, RustHound-CE, Obsidian. Source of each tool: apt / pipx / go install / cargo install / git clone — see the script. | Yes |
| 70-ssh-hardening.sh        | server         | Drop-in `sshd_config.d/99-bootstrap-hardening.conf`: PasswordAuthentication no, PermitRootLogin prohibit-password, MaxAuthTries 4, LoginGraceTime 30. Refuses to run if `$USER` has no `authorized_keys` (would lock you out). `sshd -t` before reload. | Yes |
| 80-unattended-upgrades.sh  | server         | Enables `unattended-upgrades` for **all** origins (security + main + `-updates`), no auto-reboot. Ensures `apt-daily.timer` + `apt-daily-upgrade.timer` + `unattended-upgrades.service` are enabled. Config in `apt.conf.d/99-bootstrap-unattended.conf`. | Yes |
| 85-timezone.sh             | server         | `timedatectl set-timezone Europe/Stockholm`                                                | Yes        |

## Server profile

`--server` swaps the KDE-desktop assumptions out for a headless server
posture. Runs on Debian 13 and Ubuntu LTS (24.04 / 22.04). Tested on
Proxmox guests and OCI ARM VMs.

**What runs**: `10-packages.sh` (with `packages/base.txt` +
`packages/server.txt`), `20-locale.sh` (no plasma-localerc),
`30-shell.sh`, `40-services.sh` (docker group only), then
`70-ssh-hardening.sh`, `80-unattended-upgrades.sh`, `85-timezone.sh`.

**What doesn't**: `50-yubikey.sh` (no PAM u2f), the KDE plasma-localerc
block in `20-locale.sh`, and libvirt/kvm/wireshark groups in
`40-services.sh`.

**Server package overlay** (`packages/server.txt`): `unattended-upgrades`,
`needrestart`, `ncdu`, `iotop`, `molly-guard`, `tshark`. Everything else
comes from `packages/base.txt`.

**SSH lockdown precheck**: `70-ssh-hardening.sh` refuses to write
`PasswordAuthentication no` unless `$USER` has at least one entry in
`~/.ssh/authorized_keys`. Do this before running:

```bash
# From the machine's local/serial/hypervisor console is safest —
# no risk of dropping the very SSH session you're hardening.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
printf 'ssh-ed25519 AAAA... comment\n' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**Ubuntu quirks handled**:
- `HashiCorp` apt-repo suite is picked dynamically from
  `/etc/os-release` (`trixie` / `noble` / `jammy`), not hardcoded.
- `needrestart` is flipped to `$nrconf{restart} = 'a'` so `apt install`
  runs don't hang on the interactive service-restart prompt.
- `snap`, `netplan`, and other Ubuntu-only stack are left alone.

**Unattended-upgrades policy** (`80-unattended-upgrades.sh`):
- **Everything except -proposed and -backports**: security + main
  archive point releases + `-updates`. Both Debian and Ubuntu covered by
  a single Origins-Pattern using `${distro_id}` / `${distro_codename}`.
- **No automatic reboot** — kernel/libc bumps wait for a human. Check
  needed-restarts with `needrestart -r a` or schedule a reboot via
  Ansible.
- No mail; use `journalctl -u unattended-upgrades.service` to review.
- Config lives in `/etc/apt/apt.conf.d/99-bootstrap-unattended.conf`
  (drop-in; the stock `50unattended-upgrades` stays pristine).

**Not automated** (by design — belongs in Ansible if you run it):
- Host firewall (nftables/ufw) — the perimeter is your UCG Max / OCI
  security list. A host firewall on top risks breaking VCN ingress rules.
- fail2ban — with `PasswordAuthentication no`, brute force is a non-issue.
- Monitoring agents, log shippers, backup client, app config.

## Notes on Debian 13 (Trixie) packaging quirks

- `docker-compose` (Python v1) was removed from Trixie. `docker.io` is used
  here, which provides `docker compose` (note the space, no hyphen) via the
  built-in compose subcommand. If you prefer Docker's own repository, use
  `docker-ce` and `docker-compose-plugin` from `download.docker.com` instead.
- `bat` installs the binary as `batcat` (avoids name clash with another
  package). Same applies to `fd-find` which installs as `fdfind`. Add aliases
  in `.zshrc` if you want the upstream names.
- `dig` and `host` are part of Trixie's standard system utilities task and
  are usually already installed (via `bind9-dnsutils` and `bind9-host`).
- VS Code (`code`), Terraform, and the GitHub CLI (`gh`) are not in Debian
  repos. 10-packages.sh adds the upstream apt repositories (DEB822 format)
  and signing keys via the `configure_apt_repo` helper in `common.sh`.
- The Debian suite for HashiCorp's repo is hardcoded (`trixie`) — when
  upgrading to a new Debian release, update both this and the call in
  `10-packages.sh`.
- Both `netcat-openbsd` and `netcat-traditional` register an alternative for
  `/usr/bin/nc`. 10-packages.sh pins it to the OpenBSD variant
  (`update-alternatives --set nc /bin/nc.openbsd`).
- RustHound-CE and feroxbuster are built from source via `cargo install`
  (Debian's `rust*` packages lag, and `feroxbuster` isn't packaged at all).
  Build dependencies are pulled in automatically; the Rust toolchain itself
  is installed via `rustup` if `~/.cargo/bin/cargo` is missing.
- `nikto` is in Debian only via the `non-free` component. Rather than enable
  non-free for one tool, 60-pentest-tools.sh clones nikto from upstream into
  `~/.local/opt/nikto` and symlinks `~/.local/bin/nikto` to its perl
  entrypoint. Its perl runtime deps (libwww-perl, libnet-ssleay-perl,
  libio-socket-ssl-perl, libauthen-ntlm-perl) are installed via apt.
- Wireshark's debconf question is pre-seeded so non-root users in the
  `wireshark` group can capture packets without using sudo.
- `localectl set-locale` is blocked by Debian's dbus policy (Debian bug
  #1108144) even as root. 20-locale.sh uses `update-locale` instead, which
  writes to `/etc/default/locale` — Debian's source of truth for the
  system locale.
- **Tailscale coexistence**: if `tailscaled` is already running when
  10-packages.sh installs `resolvconf`, Tailscale rewrites
  `/etc/resolv.conf` to point solely at MagicDNS (100.100.100.100).
  Tailnets with no global nameservers configured then lose external DNS —
  MagicDNS refuses to recurse for non-tailnet queries. 10-packages.sh
  warns and pauses before the install, and verifies DNS afterwards.
  Two ways to coexist:
    - **Keep MagicDNS**: add global nameservers (e.g. 1.1.1.1) at
      https://login.tailscale.com/admin/dns before running the bootstrap.
    - **Disable Tailscale DNS on this host**: `sudo tailscale set
      --accept-dns=false`. DNS falls back to DHCP/NetworkManager.

## Dotfiles checkout location

`30-shell.sh` resolves the dotfiles directory in this order:

1. `$DOTFILES_DIR` env var, if set: `DOTFILES_DIR=~/somewhere/else ./30-shell.sh`.
2. A sibling of this repo: `$(dirname linux-bootstrap)/dotfiles`. This means
   if you keep `~/repos/linux-bootstrap`, the script will use
   `~/repos/dotfiles` automatically.
3. `$HOME/dotfiles` — the simple "everything in $HOME" layout.

The first existing `.git/` checkout wins. If none exist, the script clones
into the sibling location.

## Root shares the user's dotfiles

`30-shell.sh` runs `stow` twice: once into `$HOME` and once into `/root`
(via sudo). Both end up symlinking the same files in `~/dotfiles`, so root
gets your zsh config "for free." Side-effects to be aware of:

- `/.gitconfig` becomes the user's gitconfig — root commits will carry your
  name/email. Either keep that (handy for fixing things in `/etc` as root)
  or scope the dotfiles repo so `.gitconfig` lives in a subpackage you
  selectively stow.
- Default Debian `/home` perms (`755`) let root read `/home/$USER/dotfiles`.
  If you tighten `/home` later, the symlinks break.

## Manual steps not automated

Some steps are inherently interactive or security-sensitive and are left
manual:

- Adding the SSH public key to GitHub (the script pauses and prints the key)
- Registering each YubiKey: `pamu2fcfg -n >> ~/.config/Yubico/u2f_keys`
- Generating GPG master key + subkeys (Ed25519/Curve25519)
- Logging in to 1Password / Vaultwarden
- Configuring Firefox pentest profile with FoxyProxy
- Downloading the Obsidian AppImage (60-pentest-tools.sh sets up the
  desktop integration once the AppImage is in place)
- Installing Burp Suite (download from PortSwigger and run their installer;
  not automated since the licence flow is manual)
