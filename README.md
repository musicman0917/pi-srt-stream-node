# Pi SRT Stream Node

Turn a Raspberry Pi 4 or 5 and a USB webcam into a low-latency network camera for OBS.

```
 USB webcam ──► ffmpeg (H.264) ──► MediaMTX ──► srt://PI_IP:8890 ──► OBS Media Source
 └──────────────── Raspberry Pi ─────────────┘                        (streaming PC)
```

One script does the whole setup. It installs ffmpeg and MediaMTX, finds your webcam, checks which resolutions the webcam supports, and creates services that start on boot. Then it tests the stream and tells you exactly what to paste into OBS. It can also give the Pi a static IP if you want one.

## What you need

- Raspberry Pi 5 or Pi 4 (2 GB or more), a microSD card and the official power supply
- A USB webcam that supports MJPEG. Almost all do, for example the Logitech C920, C922 or Brio.
- A PC running OBS on the same network
- Ethernet is best. 5 GHz Wi-Fi also works.

## 1. Flash the SD card

1. Open **Raspberry Pi Imager** and choose your device (Pi 4 or Pi 5).
2. For the OS, choose **Raspberry Pi OS (other) → Raspberry Pi OS Lite (64-bit)**.
3. Click **Edit settings** (gear icon) and set:
   - hostname, username and password
   - Wi-Fi network and **Wi-Fi country** (skip if using Ethernet)
   - **Services → Enable SSH** with password authentication
4. Write the card. Plug the webcam into a **blue USB 3.0 port**, then boot the Pi and give it about 2 minutes.

## 2. Run the installer

Unzip the download on your PC. Open a terminal in the unzipped folder: on Windows, right-click the folder and choose **Open in Terminal**. Then copy the installer to the Pi. Use the username and hostname you set in Imager, or the Pi's IP from your router's device list:

```bash
scp install.sh YOUR_USER@YOUR_HOSTNAME.local:~
```

Then SSH into the Pi and run it:

```bash
ssh YOUR_USER@YOUR_HOSTNAME.local
sudo bash install.sh
```

The installer asks a few questions. Every question has a default, so pressing Enter is always safe. It will:

1. Install `ffmpeg`, `v4l-utils` and the latest [MediaMTX](https://github.com/bluenviron/mediamtx), and verify the download's checksum
2. Detect your webcam and check that it can do 1080p30 MJPEG. If it can't, it offers the best mode the camera does support.
3. Create the `mediamtx` and `srt-camera` services and start them on every boot
4. Test the stream and measure the real frame rate
5. Optionally turn off Wi-Fi power saving (this prevents stutter) and set a static IP
6. Print the URL to use in OBS

If you set a static IP, reboot and SSH back in using the new address.

## 3. Add the camera in OBS

On your streaming PC:

1. **Sources → + → Media Source**, give it a name, click OK
2. Uncheck **Local File**
3. **Input:** `srt://YOUR_PI_IP:8890?streamid=read:cam` (the installer prints this with your IP filled in)
4. **Network Buffering:** `1 MB`
5. Click **OK**

## Changing settings

All camera settings live in `/etc/srt-camera.conf`:

```bash
sudo nano /etc/srt-camera.conf
sudo systemctl restart srt-camera
```

| Setting            | Default     | Notes                                                                                     |
| ------------------ | ----------- | ----------------------------------------------------------------------------------------- |
| `VIDEO_DEVICE`     | auto        | A stable `/dev/v4l/by-id/...` path, so it survives reboots and re-plugging                 |
| `VIDEO_SIZE`       | `1920x1080` | Must be a mode the camera offers. Check with `v4l2-ctl -d "$VIDEO_DEVICE" --list-formats-ext` |
| `FRAMERATE`        | `30`        |                                                                                           |
| `BITRATE`          | `8000k`     | Lower it (for example `5000k`) if Wi-Fi is weak                                           |
| `ENCODER`          | `libx264`   | `h264_v4l2m2m` uses the Pi 4's hardware encoder. The Pi 5 has no hardware encoder.        |
| `PRESET`           | `superfast` | `ultrafast` uses the least CPU, `veryfast` gives better quality                           |
| `KEYFRAME_SECONDS` | `1`         | Lower values make OBS connect and recover from drops faster                               |
| `STREAM_NAME`      | `cam`       | The OBS URL becomes `...?streamid=read:<name>`                                            |

MediaMTX's own config is at `/usr/local/etc/mediamtx.yml`.

## Everyday commands

```bash
systemctl status mediamtx srt-camera   # are the services running?
journalctl -u srt-camera -f            # live camera/ffmpeg log
journalctl -u mediamtx -f              # live server log (shows OBS connecting)
sudo systemctl restart srt-camera      # restart the camera stream
```

## Troubleshooting

| Problem | Fix |
| --- | --- |
| **"No USB webcam found"** | Run `v4l2-ctl --list-devices`. Try a different USB port or cable. |
| **OBS shows nothing** | Check the IP in the URL. Run `systemctl status srt-camera`. Make sure the PC and the Pi are on the same network. To tell a camera problem from a network problem, run `sudo bash install.sh --test-pattern`. If OBS shows the test image, the network side works. Re-run without the flag to go back to the camera. |
| **Stutter or low fps** | Read the fps the installer measured. On a Pi 4, set `PRESET="ultrafast"` or `ENCODER="h264_v4l2m2m"`. Webcams also drop to 15 fps in dim light, so add light. |
| **Picture breaks up on Wi-Fi** | Use Ethernet, lower `BITRATE`, or raise OBS Network Buffering. Re-running the installer turns off Wi-Fi power saving. |
| **Camera worked, then stopped** | Check `journalctl -u srt-camera -n 50`. The service retries every 5 seconds, so re-plugging the camera is enough. |

## Updating and uninstalling

Re-run the installer at any time. It updates MediaMTX to the latest release and keeps your settings. If you've downloaded a newer version of this installer, copy the new `install.sh` to the Pi with `scp` first, as in step 2.

```bash
sudo bash install.sh
```

To remove everything, run the line below. Add `--purge` to also delete the settings files.

```bash
sudo bash install.sh --uninstall
```

## Installer options

```
bash install.sh --help
```

| Option | Purpose |
| --- | --- |
| `-y`, `--yes` | Ask nothing; use defaults and existing settings |
| `--device PATH` | Camera to use (default: auto-detect) |
| `--test-pattern` | Stream a generated test image instead of a camera |
| `--size WxH`, `--fps N`, `--bitrate RATE` | Video mode and quality |
| `--encoder NAME`, `--preset NAME` | Encoder settings |
| `--stream-name NAME` | Stream id (default `cam`) |
| `--static-ip IP/PREFIX`, `--gateway IP`, `--dns IP` | Set a static IP without prompts |
| `--skip-network` | Leave network settings alone |
| `--mediamtx-version V` | Pin a MediaMTX release, e.g. `v1.21.1` |
| `--uninstall [--purge]` | Remove everything |

Example of a fully unattended install:

```bash
sudo bash install.sh --yes --static-ip 192.168.1.50/24 --gateway 192.168.1.1
```

## What gets installed

| Path | What it is |
| --- | --- |
| `/usr/local/bin/mediamtx` | MediaMTX server |
| `/usr/local/etc/mediamtx.yml` | MediaMTX config (kept on re-install) |
| `/usr/local/bin/srt-camera` | Script that runs ffmpeg with your settings |
| `/etc/srt-camera.conf` | Your camera settings |
| `/etc/systemd/system/mediamtx.service` | Starts MediaMTX on boot |
| `/etc/systemd/system/srt-camera.service` | Starts the camera stream on boot |

If you set up the Pi by hand before using this installer, it replaces that setup. It turns off the old `camera.service` and keeps a copy as `camera.service.bak`, and stops any `mediamtx` you started by hand. The old `~/mediamtx` folder is no longer used, and you can delete it.

<details>
<summary><strong>Manual setup (without the installer)</strong></summary>

These are the same steps the installer runs, if you'd rather do them yourself.

```bash
sudo apt update && sudo apt install -y ffmpeg v4l-utils
```

Download MediaMTX. Release file names include the version, so look up the latest version first:

```bash
VER=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/bluenviron/mediamtx/releases/latest | sed 's|.*/||')
curl -fsSLO "https://github.com/bluenviron/mediamtx/releases/download/$VER/mediamtx_${VER}_linux_arm64.tar.gz"
tar -xzf "mediamtx_${VER}_linux_arm64.tar.gz" mediamtx mediamtx.yml
sudo install -m 755 mediamtx /usr/local/bin/ && sudo install -D -m 644 mediamtx.yml /usr/local/etc/mediamtx.yml
```

Find your camera's stable path. Use the entry ending in `-video-index0`:

```bash
ls /dev/v4l/by-id/
```

Test it. Quote the URL, because `?` and `&` are special characters in the shell:

```bash
mediamtx /usr/local/etc/mediamtx.yml &
ffmpeg -f v4l2 -input_format mjpeg -framerate 30 -video_size 1920x1080 -i /dev/v4l/by-id/YOUR-CAMERA-video-index0 \
  -an -c:v libx264 -preset superfast -tune zerolatency -profile:v high -pix_fmt yuv420p -g 30 \
  -b:v 8000k -maxrate 8000k -bufsize 8000k \
  -f mpegts "srt://127.0.0.1:8890?streamid=publish:cam&pkt_size=1316"
```

Press Ctrl+C, then run `kill %1`. For starting on boot, create the two systemd units listed under [What gets installed](#what-gets-installed). Then give the Pi a fixed address, either with a DHCP reservation in your router or with `sudo nmtui` → Edit a connection → IPv4 → Manual.

</details>

## Optional: desktop and remote GUI

If you'd rather manage the Pi with a desktop than over SSH, flash **Raspberry Pi OS (with desktop)** instead of Lite. Then set up [Raspberry Pi Connect](https://www.raspberrypi.com/software/connect/) to reach the desktop from any web browser. The installer works the same on either image, but Lite leaves more CPU for encoding.

## License

MIT. See [LICENSE](LICENSE). The installer downloads [MediaMTX](https://github.com/bluenviron/mediamtx), which is MIT-licensed by its own authors.
