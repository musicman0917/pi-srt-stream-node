# Raspberry Pi OS-like container for testing install.sh without a Pi.
#
# Raspberry Pi OS is Debian plus the Raspberry Pi apt repo, so this is arm64
# Debian with that repo added (same ffmpeg build as a real Pi) and systemd
# running as PID 1. It has no camera, Wi-Fi or Pi hardware; see test/README.md.
ARG RELEASE=trixie
FROM debian:${RELEASE}
ARG RELEASE

ENV container=docker

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg systemd systemd-sysv sudo iproute2 procps \
 && curl -fsSL https://archive.raspberrypi.com/debian/raspberrypi.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/raspberrypi-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.com/debian/ ${RELEASE} main" \
      > /etc/apt/sources.list.d/raspi.list \
 && rm -rf /var/lib/apt/lists/*

# Same default account setup as Raspberry Pi OS: uid 1000, passwordless sudo, video group.
RUN useradd -m -u 1000 -G sudo,video -s /bin/bash pi \
 && echo 'pi ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/010_pi-nopasswd

# Console logins are meaningless in a container and only slow down boot.
RUN systemctl mask getty.target console-getty.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
