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

## Hostname detection

`hosts.conf` controls machine-specific decisions. Add new machines there.
Scripts read `role`, `is_pentest` and `is_vm` from this file.

```
hostname        role        is_pentest    is_vm
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

## What each script does

| Script              | Description                                                          | Idempotent |
|---------------------|----------------------------------------------------------------------|------------|
| 00-bootstrap.sh     | SSH key, clone this repo                                             | Yes        |
| 10-packages.sh      | Installs apt packages from packages.txt (includes VS Code repo)      | Yes        |
| 20-locale.sh        | sv_SE.UTF-8 locale + KDE plasma-localerc + sshd AcceptEnv            | Yes        |
| 30-shell.sh         | zsh as default + clone & stow dotfiles + ssh-agent user unit         | Yes        |
| 40-services.sh      | docker/libvirt/wireshark groups, libvirt default network             | Yes        |
| 50-yubikey.sh       | libpam-u2f, PAM config for sudo and SDDM                             | Yes        |
| 60-pentest-tools.sh | Burp, nuclei, subfinder, httpx, semgrep, RustHound-CE, Obsidian      | Yes        |

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
- VS Code (`code`) is not in Debian repos; 10-packages.sh adds the official
  Microsoft apt repository (DEB822 format) and signing key automatically.
- RustHound-CE is built from source via `cargo install rusthound-ce` (Debian's
  rust packages can lag behind what it needs). Build dependencies are pulled
  in automatically; the Rust toolchain itself is installed via `rustup` if
  `cargo` is missing.
- Wireshark's debconf question is pre-seeded so non-root users in the
  `wireshark` group can capture packets without using sudo.

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
- HP Z40c G3 firmware update on the T14 (if still pending)
