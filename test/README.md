# Testing install.sh in Docker

[`Dockerfile`](Dockerfile) builds a Raspberry Pi OS-like container: arm64 Debian, the Raspberry Pi apt repo (so `ffmpeg` is the same build a real Pi installs) and systemd. It runs on a normal PC through Docker's built-in arm64 emulation.

## What it covers and what it doesn't

| Covered | Not covered (needs a real Pi) |
| --- | --- |
| apt install of the Pi's `ffmpeg` and `v4l-utils` | USB webcam detection and MJPEG mode checks |
| MediaMTX arm64 download, checksum, re-run "already installed" check | Wi-Fi power saving and static IP (no NetworkManager in the container) |
| systemd services starting, restarting and uninstalling | Real performance (emulation is 5-10x slower, so ignore the measured fps) |
| The full stream pipeline, using `--test-pattern` instead of a camera | `/proc/device-tree/model` (the installer warns it isn't a Pi; that's expected) |
| Interactive prompts, `--yes`, re-runs | |

## Run it

Install Docker Desktop first. Run these from the repo root in PowerShell.

Build the image. This takes a few minutes the first time because of the emulation:

```powershell
docker build --platform linux/arm64 -t pi-srt-test test
```

Start the container with systemd running. The repo is mounted read-only at `/repo`:

```powershell
docker run -d --name pi-srt-test --platform linux/arm64 --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -v "${PWD}:/repo:ro" pi-srt-test
```

Run the installer as the `pi` user. Use a small test pattern so the emulated encoder can keep up:

```powershell
docker exec -it -u pi -w /repo pi-srt-test sudo bash install.sh --test-pattern --size 640x360 --preset ultrafast
```

Things worth trying next:

- Run the same command again. It should report MediaMTX as already installed and load your existing settings.
- Add `--yes` to check the unattended path.
- Run `docker exec -it -u pi pi-srt-test bash` and then `systemctl status mediamtx srt-camera` or `journalctl -u srt-camera`.
- Uninstall with `docker exec -it -u pi -w /repo pi-srt-test sudo bash install.sh --uninstall`.

To test the older Bookworm-based Raspberry Pi OS, add `--build-arg RELEASE=bookworm` to the build command and use a different tag.

Clean up when you're done:

```powershell
docker rm -f pi-srt-test
```
