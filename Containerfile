# Debian 13 (Trixie) smoke-test image for linux-bootstrap.
#
# The container creates a normal user 'tester' with passwordless sudo and
# copies the repo into ~/linux-bootstrap. Run-all.sh expects to be invoked as
# this user with BOOTSTRAP_SMOKE=1 so dotfiles cloning, ssh-agent systemd
# enablement, libvirt activation, and YubiKey PAM are all skipped.
#
# The synthetic hostname 'bootstrap-smoke' is *not* listed in hosts.conf, so
# defaults apply: role=daily, is_pentest=no, is_vm=no. We override is_vm via
# BOOTSTRAP_SMOKE-aware checks where applicable, but to also exercise the
# pentest-tools script set is_pentest=yes here by appending a hosts.conf line.

FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        sudo curl wget git ca-certificates locales \
        bash hostname procps psmisc systemd \
    && rm -rf /var/lib/apt/lists/*

ARG USERNAME=tester
RUN useradd -m -s /bin/bash "$USERNAME" \
    && usermod -aG sudo "$USERNAME" \
    && echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME
WORKDIR /home/$USERNAME

COPY --chown=$USERNAME:$USERNAME . /home/$USERNAME/linux-bootstrap/

# Mark the smoke hostname as a pentest VM so 50-yubikey skips and 60-pentest
# runs. The runtime --hostname flag is what 'hostname' reports.
RUN printf '\nbootstrap-smoke daily yes yes\n' \
    | tee -a /home/$USERNAME/linux-bootstrap/hosts.conf

WORKDIR /home/$USERNAME/linux-bootstrap

CMD ["bash", "-lc", "./run-all.sh"]
