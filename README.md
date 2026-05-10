# linux-bootstrap

Numbered, idempotent scripts for setting up a fresh Debian 13 (Trixie) +
KDE machine the same way every time. Scripts are safe to re-run.

The repo only contains setup scripts. Dotfiles live in a separate repo
(`rosboll/dotfiles`) and are cloned and stowed by `30-shell.sh`.

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

```bash
# 1. Bootstrap (generates SSH key, asks you to add it to GitHub,
#    clones this repo)
bash <(curl -sSL https://raw.githubusercontent.com/rosboll/linux-bootstrap/main/00-bootstrap.sh)

# That clones the repo to ~/linux-bootstrap. Run the rest from there:
cd ~/linux-bootstrap

# 2. Run remaining scripts in order, or all at once via run-all.sh
./10-packages.sh
./20-locale.sh
./30-shell.sh           # also clones rosboll/dotfiles and stows it
./40-services.sh
./50-yubikey.sh
./60-pentest-tools.sh   # only if hosts.conf marks the machine as pentest

# Or everything in one go (after 00-bootstrap):
./run-all.sh
```

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

…or have your dotfiles do it for you in `~/.zlogin`:

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
hangs, this is what you're hitting.

## Hostname detection

`hosts.conf` controls machine-specific decisions. Add new machines there.
Scripts read `role`, `is_pentest` and `is_vm` from this file. The lookup is
case-insensitive.

The columns are: `hostname role is_pentest is_vm` — that line is *not*
present in the file itself, only the data rows.

```
t14             daily       yes           no
p52             lab         yes           no
p15             homelab     no            no
ColorJet4250    daily       yes           no
kaliv           lab         yes           yes
```

If the current hostname is not listed, defaults are used (`role=daily`,
`is_pentest=no`, `is_vm=no`).

`is_vm=yes` skips:

- Virtualization packages (qemu, libvirt, virt-manager, ...) in 10-packages.sh
- libvirt/kvm group membership and the libvirt default network in 40-services.sh
- The entire 50-yubikey.sh (no physical YubiKey is plugged into a VM)

Docker is kept on VMs since it is useful inside a Kali VM as well.

## Smoke test (container)

The repo includes a `Containerfile` and a `Makefile` that boots Debian 13 in
a container, copies the repo in, and runs `run-all.sh` end-to-end with
`BOOTSTRAP_SMOKE=1` set. That env var makes scripts skip operations that
need credentials or hardware we don't have inside a container:

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
for CI. The container hostname is `bootstrap-smoke` and it gets injected
into `hosts.conf` at image build time as `is_pentest=yes is_vm=yes`.

## What each script does

| Script              | Description                                                          | Idempotent |
|---------------------|----------------------------------------------------------------------|------------|
| 00-bootstrap.sh     | SSH key, clone this repo                                             | Yes        |
| 10-packages.sh      | Installs apt packages from packages.txt (VS Code, HashiCorp, gh repos) | Yes      |
| 20-locale.sh        | sv_SE.UTF-8 locale + KDE plasma-localerc + sshd AcceptEnv            | Yes        |
| 30-shell.sh         | zsh as default for $USER and root + clone & stow dotfiles into both + ssh-agent user unit + mask gcr-ssh-agent | Yes |
| 40-services.sh      | docker/libvirt/wireshark groups, libvirt default network             | Yes        |
| 50-yubikey.sh       | libpam-u2f, PAM config for sudo (touch only), SDDM and KDE lock screen (PIN + touch) | Yes |
| 60-pentest-tools.sh | nuclei, subfinder, httpx, naabu, ffuf, gobuster, kerbrute, mitmproxy, netexec, responder, sqlmap, nikto, hydra, feroxbuster, semgrep, impacket, certipy-ad, RustHound-CE, Obsidian. Source of each tool: apt / pipx / go install / cargo install / git clone — see the script. | Yes |

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
- HP Z40c G3 firmware update on the T14 (if still pending)
