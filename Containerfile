# Debian 13 (Trixie) smoke-test image for linux-bootstrap.
#
# The container creates a normal user 'tester' with passwordless sudo and
# copies the repo into ~/linux-bootstrap. Run-all.sh is invoked with
# BOOTSTRAP_SMOKE=1 so dotfiles cloning, ssh-agent systemd enablement,
# libvirt activation, and YubiKey PAM are all skipped. --pentest is passed
# so that 60-pentest-tools.sh is also exercised (apt prereqs only in smoke
# mode).

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

WORKDIR /home/$USERNAME/linux-bootstrap

CMD ["bash", "-lc", "BOOTSTRAP_SMOKE=1 ./run-all.sh --pentest"]
