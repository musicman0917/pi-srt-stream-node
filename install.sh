#!/usr/bin/env bash
#
# Pi SRT Stream Node installer
#
# Turns a Raspberry Pi 4/5 running Raspberry Pi OS Lite (64-bit) plus a USB
# webcam into a low-latency SRT camera that OBS can pull over the network:
#
#   webcam -> ffmpeg (H.264) -> MediaMTX -> srt://<pi-ip>:8890?streamid=read:cam -> OBS
#
#   sudo bash install.sh                interactive install (re-run any time to update)
#   sudo bash install.sh --yes          use defaults, ask nothing
#   sudo bash install.sh --uninstall    remove services and binaries
#   bash install.sh --help              all options
#
# Everything runs from main() at the bottom, so piping works too:
#   curl -fsSL <raw-url>/install.sh | sudo bash
#
set -euo pipefail

readonly VERSION=1.0.1
readonly MEDIAMTX_REPO=bluenviron/mediamtx
readonly MEDIAMTX_BIN=/usr/local/bin/mediamtx
readonly MEDIAMTX_CONF=/usr/local/etc/mediamtx.yml
readonly CAMERA_BIN=/usr/local/bin/srt-camera
readonly CONFIG_FILE=/etc/srt-camera.conf
readonly UNIT_DIR=/etc/systemd/system

# Stream defaults. An existing $CONFIG_FILE overrides these; flags override both.
VIDEO_DEVICE=
INPUT_FORMAT=mjpeg
VIDEO_SIZE=1920x1080
FRAMERATE=30
ENCODER=libx264
PRESET=superfast
BITRATE=8000k
KEYFRAME_SECONDS=1
STREAM_NAME=cam
SRT_PORT=8890
LOG_LEVEL=warning

# Installer state
ACTION=install
ASSUME_YES=0
INTERACTIVE=0
PURGE=0
SKIP_NETWORK=0
TEST_PATTERN=0
MEDIAMTX_VERSION=latest
RUN_USER=
STATIC_IP=
GATEWAY=
DNS=1.1.1.1
OPT_DEVICE= OPT_SIZE= OPT_FPS= OPT_BITRATE= OPT_ENCODER= OPT_PRESET= OPT_STREAM=
PI_MODEL=
NODE_IP=
NEEDS_REBOOT=0
STREAM_OK=0
TMP_DIR=
trap '[[ -z $TMP_DIR ]] || rm -rf "$TMP_DIR"' EXIT

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
  BOLD= RED= GREEN= YELLOW= CYAN= RESET=
fi

step() { printf '\n%s==> %s%s\n' "$BOLD$CYAN" "$*" "$RESET"; }
ok()   { printf '  %s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
note() { printf '      %s\n' "$*"; }
warn() { printf '  %s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '\n%sError:%s %s\n' "$BOLD$RED" "$RESET" "$*" >&2; exit 1; }

# ask VAR "Question" default -- reads from the terminal even when the script is piped.
ask() {
  local __reply=
  if (( INTERACTIVE )); then
    read -r -p "  $2 [$3]: " __reply </dev/tty || __reply=
  fi
  printf -v "$1" '%s' "${__reply:-$3}"
}

# confirm "Question" y|n -- succeeds on yes; returns the default when not interactive.
confirm() {
  local reply= hint=y/N
  [[ $2 == y ]] && hint=Y/n
  if (( INTERACTIVE )); then
    read -r -p "  $1 [$hint] " reply </dev/tty || reply=
  fi
  [[ ${reply:-$2} =~ ^[Yy] ]]
}

usage() {
  cat <<EOF
Pi SRT Stream Node installer v$VERSION

Usage: sudo bash install.sh [options]

Install options:
  -y, --yes                  Ask nothing; use defaults and existing settings
      --device PATH          Camera device (default: auto-detect USB webcam)
      --test-pattern         Stream a generated test image instead of a camera
                             (for checking OBS, or testing without a webcam)
      --size WxH             Capture resolution (default: $VIDEO_SIZE)
      --fps N                Frame rate (default: $FRAMERATE)
      --bitrate RATE         Video bitrate, e.g. 8000k or 6M (default: $BITRATE)
      --encoder NAME         libx264 (default) or h264_v4l2m2m (Pi 4 hardware)
      --preset NAME          libx264 preset: ultrafast|superfast|veryfast (default: $PRESET)
      --stream-name NAME     SRT stream id OBS reads (default: $STREAM_NAME)
      --user NAME            Account the services run as (default: the sudo user)
      --mediamtx-version V   Pin a MediaMTX release, e.g. v1.21.1 (default: latest)

Network options (take effect after a reboot):
      --static-ip IP/PREFIX  Set a static IP, e.g. 192.168.1.50/24
      --gateway IP           Router address (default: current gateway)
      --dns IP               DNS server (default: $DNS)
      --skip-network         Leave network settings alone

Other:
      --uninstall            Remove services and binaries (keeps settings)
      --purge                With --uninstall, also delete settings
  -h, --help                 Show this help
EOF
}

parse_args() {
  while (( $# )); do
    case $1 in
      -y|--yes)           ASSUME_YES=1 ;;
      --device)           OPT_DEVICE=${2:?"$1 needs a value"}; shift ;;
      --test-pattern)     TEST_PATTERN=1 ;;
      --size)             OPT_SIZE=${2:?"$1 needs a value"}; shift ;;
      --fps)              OPT_FPS=${2:?"$1 needs a value"}; shift ;;
      --bitrate)          OPT_BITRATE=${2:?"$1 needs a value"}; shift ;;
      --encoder)          OPT_ENCODER=${2:?"$1 needs a value"}; shift ;;
      --preset)           OPT_PRESET=${2:?"$1 needs a value"}; shift ;;
      --stream-name)      OPT_STREAM=${2:?"$1 needs a value"}; shift ;;
      --user)             RUN_USER=${2:?"$1 needs a value"}; shift ;;
      --mediamtx-version) MEDIAMTX_VERSION=${2:?"$1 needs a value"}; shift ;;
      --static-ip)        STATIC_IP=${2:?"$1 needs a value"}; shift ;;
      --gateway)          GATEWAY=${2:?"$1 needs a value"}; shift ;;
      --dns)              DNS=${2:?"$1 needs a value"}; shift ;;
      --skip-network)     SKIP_NETWORK=1 ;;
      --uninstall)        ACTION=uninstall ;;
      --purge)            PURGE=1 ;;
      -h|--help)          usage; exit 0 ;;
      *)                  die "Unknown option '$1' (see --help)" ;;
    esac
    shift
  done
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Please run with sudo, e.g.:  sudo bash install.sh"
}

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------

preflight() {
  step "Checking system (Pi SRT Stream Node installer v$VERSION)"
  require_root
  command -v apt-get >/dev/null || die "This installer needs a Debian-based OS such as Raspberry Pi OS."
  [[ -d /run/systemd/system ]] || die "systemd isn't running, so services can't be installed."

  if (( ! ASSUME_YES )) && { : </dev/tty; } 2>/dev/null; then
    INTERACTIVE=1
  fi

  RUN_USER=${RUN_USER:-${SUDO_USER:-}}
  if [[ -z $RUN_USER || $RUN_USER == root ]]; then
    RUN_USER=$(getent passwd 1000 | cut -d: -f1 || true)
  fi
  [[ -n $RUN_USER ]] && id "$RUN_USER" >/dev/null 2>&1 \
    || die "Couldn't work out which user should run the services; pass --user NAME."

  if [[ -r /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' </proc/device-tree/model)
  fi
  ok "Device: ${PI_MODEL:-unknown}"
  ok "OS: $( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null || echo unknown) ($(uname -m))"
  ok "Services will run as: $RUN_USER"

  case $PI_MODEL in
    *"Pi 4"*|*"Pi 5"*|*"Pi 400"*|*"Pi 500"*|*"Module 4"*|*"Module 5"*) ;;
    *"Raspberry Pi"*) warn "This guide targets the Pi 4 and Pi 5; older models may struggle to encode 1080p." ;;
    *) warn "This doesn't look like a Raspberry Pi; continuing anyway." ;;
  esac
  if [[ $(uname -m) != aarch64 ]]; then
    warn "Raspberry Pi OS Lite (64-bit) is recommended; you're on $(uname -m)."
  fi
}

load_settings() {
  if [[ -f $CONFIG_FILE ]]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    ok "Loaded your existing settings from $CONFIG_FILE"
  fi
  VIDEO_DEVICE=${OPT_DEVICE:-$VIDEO_DEVICE}
  VIDEO_SIZE=${OPT_SIZE:-$VIDEO_SIZE}
  FRAMERATE=${OPT_FPS:-$FRAMERATE}
  BITRATE=${OPT_BITRATE:-$BITRATE}
  ENCODER=${OPT_ENCODER:-$ENCODER}
  PRESET=${OPT_PRESET:-$PRESET}
  STREAM_NAME=${OPT_STREAM:-$STREAM_NAME}
  if (( TEST_PATTERN )); then
    VIDEO_DEVICE=testpattern
  elif [[ $VIDEO_DEVICE == testpattern ]]; then
    VIDEO_DEVICE=  # the test pattern lasts until the next normal run, which looks for a camera again
  fi
  validate_settings
}

validate_settings() {
  [[ $VIDEO_SIZE =~ ^[0-9]+x[0-9]+$ ]]      || die "Invalid size '$VIDEO_SIZE' (expected e.g. 1920x1080)."
  [[ $FRAMERATE =~ ^[0-9]+$ ]]              || die "Invalid frame rate '$FRAMERATE'."
  [[ $BITRATE =~ ^[0-9]+[kKmM]?$ ]]         || die "Invalid bitrate '$BITRATE' (expected e.g. 8000k or 6M)."
  [[ $STREAM_NAME =~ ^[A-Za-z0-9_-]+$ ]]    || die "Invalid stream name '$STREAM_NAME' (letters, digits, - and _ only)."
  [[ $KEYFRAME_SECONDS =~ ^[1-9][0-9]*$ ]]  || die "Invalid KEYFRAME_SECONDS '$KEYFRAME_SECONDS'."
  [[ $SRT_PORT =~ ^[0-9]+$ ]]               || die "Invalid SRT_PORT '$SRT_PORT'."
  [[ $INPUT_FORMAT =~ ^[a-z0-9_]+$ ]]       || die "Invalid INPUT_FORMAT '$INPUT_FORMAT'."
  [[ $PRESET =~ ^[a-z]+$ ]]                 || die "Invalid preset '$PRESET'."
  [[ $LOG_LEVEL =~ ^[a-z]+$ ]]              || die "Invalid LOG_LEVEL '$LOG_LEVEL'."
  case $ENCODER in
    libx264) ;;
    h264_v4l2m2m)
      [[ -e /dev/video11 ]] || die "No hardware H.264 encoder found (the Pi 5 doesn't have one). Use --encoder libx264."
      ;;
    *) die "Unsupported encoder '$ENCODER' (use libx264 or h264_v4l2m2m)." ;;
  esac
}

install_packages() {
  step "Installing ffmpeg and camera tools (can take a few minutes on a fresh Pi)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q </dev/null >/dev/null
  apt-get install -y -q ffmpeg v4l-utils curl ca-certificates </dev/null >/dev/null
  ok "ffmpeg, v4l-utils and curl are installed"

  # Capture ffmpeg's lists first: grep -q on a pipe would trip pipefail.
  local protocols encoders
  protocols=$(ffmpeg -hide_banner -protocols </dev/null 2>/dev/null || true)
  grep -qw srt <<<"$protocols" || die "This ffmpeg build has no SRT support."
  encoders=$(ffmpeg -hide_banner -encoders </dev/null 2>/dev/null || true)
  grep -qw "$ENCODER" <<<"$encoders" || die "This ffmpeg build has no $ENCODER encoder."
  ok "ffmpeg supports SRT and $ENCODER"
}

# Prints "Card name (/dev/path)" for a camera device.
camera_label() {
  if [[ $1 == testpattern ]]; then
    printf 'Generated test pattern'
    return
  fi
  local name
  name=$(v4l2-ctl -d "$1" --info 2>/dev/null | sed -n 's/^[[:space:]]*Card type[[:space:]]*:[[:space:]]*//p' || true)
  printf '%s (%s)' "${name:-USB camera}" "$1"
}

# /dev/videoN can change between boots; prefer the matching /dev/v4l/by-id link.
stable_path() {
  local link
  for link in /dev/v4l/by-id/*-video-index*; do
    if [[ -e $link && $(readlink -f "$link") == "$(readlink -f "$1")" ]]; then
      echo "$link"
      return
    fi
  done
  echo "$1"
}

choose_camera() {
  step "Finding your camera"
  if [[ $VIDEO_DEVICE == testpattern ]]; then
    ok "Using a generated test pattern instead of a camera"
    return
  fi
  if [[ -n $VIDEO_DEVICE ]]; then
    if [[ -e $VIDEO_DEVICE ]]; then
      VIDEO_DEVICE=$(stable_path "$VIDEO_DEVICE")
      ok "Using $(camera_label "$VIDEO_DEVICE")"
      return
    fi
    [[ -z $OPT_DEVICE ]] || die "Camera '$VIDEO_DEVICE' doesn't exist."
    warn "Previously configured camera $VIDEO_DEVICE isn't connected; searching again."
  fi

  local cams=() i pick
  shopt -s nullglob
  cams=(/dev/v4l/by-id/*-video-index0)
  shopt -u nullglob

  if (( ${#cams[@]} == 0 )); then
    v4l2-ctl --list-devices 2>/dev/null || true
    die "No USB webcam found. Plug it in (blue USB 3.0 port) and re-run, or pass --device /dev/videoN."
  elif (( ${#cams[@]} == 1 )); then
    VIDEO_DEVICE=${cams[0]}
  else
    echo "  Found ${#cams[@]} cameras:"
    for i in "${!cams[@]}"; do
      printf '    %d) %s\n' "$((i + 1))" "$(camera_label "${cams[i]}")"
    done
    ask pick "Which camera should stream?" 1
    [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#cams[@]} )) || die "Invalid choice '$pick'."
    VIDEO_DEVICE=${cams[pick - 1]}
  fi
  ok "Using $(camera_label "$VIDEO_DEVICE")"
}

# Prints each MJPEG mode the camera offers as "WIDTHxHEIGHT FPS", one per line.
mjpeg_modes() {
  v4l2-ctl -d "$1" --list-formats-ext 2>/dev/null | awk '
    /\[[0-9]+\]:/        { mjpeg = ($0 ~ /MJPG/) }
    mjpeg && /Size:/     { size = $3 }
    mjpeg && /Interval:/ {
      fps = $4; sub(/^\(/, "", fps)
      mode = sprintf("%s %.0f", size, fps)
      if (!seen[mode]++) print mode
    }' || true
}

# Picks the largest mode at the wanted frame rate, else the largest mode that
# still runs at 24+ fps, else the largest mode overall.
best_mode() {
  awk -v want="$2" '
    { split($1, d, "x"); score = ($2 == want) * 1e12 + ($2 >= 24) * 1e11 + d[1] * d[2] * 1000 + $2 }
    score > best { best = score; pick = $0 }
    END { print pick }' <<<"$1"
}

choose_mode() {
  [[ $INPUT_FORMAT == mjpeg && $VIDEO_DEVICE != testpattern ]] || return 0
  local modes mode
  modes=$(mjpeg_modes "$VIDEO_DEVICE")
  if [[ -z $modes ]]; then
    warn "Couldn't read MJPEG modes from this camera; trying $VIDEO_SIZE @ $FRAMERATE fps anyway."
    note "If the stream fails, check: v4l2-ctl -d $VIDEO_DEVICE --list-formats-ext"
    return 0
  fi
  if grep -qx "$VIDEO_SIZE $FRAMERATE" <<<"$modes"; then
    ok "Camera supports MJPEG $VIDEO_SIZE @ $FRAMERATE fps"
    return 0
  fi

  warn "This camera doesn't offer MJPEG $VIDEO_SIZE @ $FRAMERATE fps. It supports:"
  awk '{ if (!($1 in fps)) order[++n] = $1; fps[$1] = fps[$1] " " $2 }
       END { for (i = 1; i <= n; i++) printf "        %-10s%s fps\n", order[i], fps[order[i]] }' <<<"$modes"
  ask mode "Resolution and fps to use" "$(best_mode "$modes" "$FRAMERATE")"
  read -r VIDEO_SIZE FRAMERATE <<<"${mode//@/ }"
  validate_settings
  ok "Using $VIDEO_SIZE @ $FRAMERATE fps"
}

print_settings() {
  local encoder=$ENCODER
  [[ $ENCODER == libx264 ]] && encoder+=" ($PRESET preset)"
  printf '    %-12s %s\n' \
    "Camera"      "$(camera_label "$VIDEO_DEVICE")" \
    "Video"       "$VIDEO_SIZE @ $FRAMERATE fps" \
    "Encoder"     "$encoder" \
    "Bitrate"     "$BITRATE" \
    "Stream name" "$STREAM_NAME"
}

review_settings() {
  step "Stream settings"
  print_settings
  (( INTERACTIVE )) || return 0
  confirm "Use these settings?" y && return 0

  local old_mode="$VIDEO_SIZE $FRAMERATE"
  ask VIDEO_SIZE "Resolution" "$VIDEO_SIZE"
  ask FRAMERATE "Frame rate" "$FRAMERATE"
  ask BITRATE "Bitrate (e.g. 8000k, 6M)" "$BITRATE"
  if [[ $ENCODER == libx264 ]]; then
    ask PRESET "x264 preset (ultrafast uses the least CPU)" "$PRESET"
  fi
  ask STREAM_NAME "Stream name" "$STREAM_NAME"
  validate_settings
  if [[ "$VIDEO_SIZE $FRAMERATE" != "$old_mode" ]]; then
    choose_mode
  fi
}

# Stops our services plus anything left over from the manual guide, which would
# otherwise hold the camera or port 8890.
stop_existing() {
  systemctl stop srt-camera.service mediamtx.service >/dev/null 2>&1 || true

  local legacy=$UNIT_DIR/camera.service
  if [[ -f $legacy ]] && grep -q 'streamid=publish' "$legacy"; then
    systemctl disable --now camera.service >/dev/null 2>&1 || true
    mv "$legacy" "$legacy.bak"
    ok "Retired camera.service from the manual setup (saved as $legacy.bak)"
  fi

  if pgrep -x mediamtx >/dev/null || pgrep -f 'streamid=publish:' >/dev/null; then
    warn "MediaMTX or an ffmpeg test stream is still running from a manual start."
    if confirm "Stop it so the new services can use the camera and port $SRT_PORT?" y; then
      pkill -x mediamtx || true
      pkill -f 'streamid=publish:' || true
      sleep 1
      ok "Stopped"
    fi
  fi
}

install_mediamtx() {
  step "Installing MediaMTX"
  stop_existing

  local names tag url base asset name current expected actual
  case $(uname -m) in
    aarch64|arm64) names=(linux_arm64 linux_arm64v8) ;;  # arm64v8 = name used by older releases
    armv7l)        names=(linux_armv7) ;;
    armv6l)        names=(linux_armv6) ;;
    x86_64)        names=(linux_amd64) ;;
    *)             die "MediaMTX has no build for $(uname -m)." ;;
  esac

  if [[ $MEDIAMTX_VERSION == latest ]]; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$MEDIAMTX_REPO/releases/latest") \
      || die "Couldn't reach GitHub to look up the latest MediaMTX release."
    tag=${url##*/}
  else
    tag=v${MEDIAMTX_VERSION#v}
  fi
  [[ $tag =~ ^v[0-9] ]] || die "Couldn't work out the MediaMTX version (got '$tag')."

  current=$("$MEDIAMTX_BIN" --version 2>/dev/null || true)
  if [[ $current == "$tag" && -f $MEDIAMTX_CONF ]]; then
    ok "MediaMTX $tag is already installed"
    return
  fi

  # Release files carry the version in their name (mediamtx_v1.2.3_linux_arm64.tar.gz),
  # so a fixed .../latest/download/<name> URL can't work.
  TMP_DIR=$(mktemp -d)
  base="https://github.com/$MEDIAMTX_REPO/releases/download/$tag"
  asset=
  for name in "${names[@]}"; do
    if curl -fsSL --retry 3 -o "$TMP_DIR/mediamtx_${tag}_$name.tar.gz" "$base/mediamtx_${tag}_$name.tar.gz" 2>/dev/null; then
      asset=mediamtx_${tag}_$name.tar.gz
      break
    fi
  done
  [[ -n $asset ]] || die "Couldn't download MediaMTX $tag for $(uname -m)."

  if curl -fsSL --retry 3 -o "$TMP_DIR/checksums.sha256" "$base/checksums.sha256" 2>/dev/null; then
    expected=$(awk -v f="$asset" '{ sub(/^\*/, "", $2) } $2 == f { print $1 }' "$TMP_DIR/checksums.sha256")
    actual=$(sha256sum "$TMP_DIR/$asset" | cut -d' ' -f1)
    if [[ -z $expected ]]; then
      warn "No published checksum for $asset; skipping verification."
    elif [[ $expected != "$actual" ]]; then
      die "Checksum mismatch for $asset; the download may be corrupted. Please re-run."
    fi
  else
    warn "No checksum file published for MediaMTX $tag; skipping verification."
  fi

  tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR" mediamtx mediamtx.yml
  install -m 0755 "$TMP_DIR/mediamtx" "$MEDIAMTX_BIN"
  ok "Installed MediaMTX $tag to $MEDIAMTX_BIN"

  if [[ -f $MEDIAMTX_CONF ]]; then
    ok "Kept your existing $MEDIAMTX_CONF"
  else
    install -D -m 0644 "$TMP_DIR/mediamtx.yml" "$MEDIAMTX_CONF"
    ok "Installed default config to $MEDIAMTX_CONF"
  fi
}

write_config() {
  cat >"$CONFIG_FILE" <<EOF
# Pi SRT Stream Node camera settings (written by install.sh).
# Apply changes with:  sudo systemctl restart srt-camera

# Camera device. The /dev/v4l/by-id path stays the same across reboots.
# List cameras with:  v4l2-ctl --list-devices
# "testpattern" streams a generated test image instead.
VIDEO_DEVICE="$VIDEO_DEVICE"

# Capture mode. Must be a combination the camera offers:
#   v4l2-ctl -d "\$VIDEO_DEVICE" --list-formats-ext
INPUT_FORMAT="$INPUT_FORMAT"
VIDEO_SIZE="$VIDEO_SIZE"
FRAMERATE="$FRAMERATE"

# libx264 = software encoder (Pi 4 and Pi 5). h264_v4l2m2m = Pi 4 hardware encoder.
ENCODER="$ENCODER"
# libx264 speed preset: ultrafast (least CPU) | superfast | veryfast (best quality)
PRESET="$PRESET"
BITRATE="$BITRATE"
# Seconds between keyframes. Lower = OBS connects and recovers from drops faster.
KEYFRAME_SECONDS="$KEYFRAME_SECONDS"

# OBS reads:  srt://<pi-ip>:SRT_PORT?streamid=read:STREAM_NAME
# SRT_PORT must match srtAddress in $MEDIAMTX_CONF
STREAM_NAME="$STREAM_NAME"
SRT_PORT="$SRT_PORT"

# ffmpeg log detail shown by "journalctl -u srt-camera": error | warning | info
LOG_LEVEL="$LOG_LEVEL"
EOF
  chmod 0644 "$CONFIG_FILE"
}

write_camera_script() {
  cat >"$CAMERA_BIN" <<'EOF'
#!/usr/bin/env bash
# Captures the USB webcam, encodes H.264 and publishes it to the local MediaMTX
# server over SRT. Started by srt-camera.service; settings: /etc/srt-camera.conf
set -euo pipefail

# shellcheck source=/dev/null
. "${SRT_CAMERA_CONFIG:-/etc/srt-camera.conf}"
: "${INPUT_FORMAT:=mjpeg}" "${VIDEO_SIZE:=1920x1080}" "${FRAMERATE:=30}" "${ENCODER:=libx264}"
: "${PRESET:=superfast}" "${BITRATE:=8000k}" "${KEYFRAME_SECONDS:=1}" "${STREAM_NAME:=cam}"
: "${SRT_PORT:=8890}" "${LOG_LEVEL:=warning}"

if [[ $VIDEO_DEVICE == testpattern ]]; then
  input=(-re -f lavfi -i "testsrc2=size=${VIDEO_SIZE}:rate=${FRAMERATE}")
elif [[ -e $VIDEO_DEVICE ]]; then
  input=(-f v4l2 -input_format "$INPUT_FORMAT" -framerate "$FRAMERATE" -video_size "$VIDEO_SIZE" -i "$VIDEO_DEVICE")
else
  echo "Camera $VIDEO_DEVICE not found. Is it plugged in? Retrying shortly." >&2
  exit 1
fi

case $ENCODER in
  libx264) encoder=(-c:v libx264 -preset "$PRESET" -tune zerolatency -profile:v high) ;;
  *)       encoder=(-c:v "$ENCODER") ;;
esac

# -pix_fmt yuv420p: most webcams' MJPEG decodes to 4:2:2, which High profile rejects
#                   and many decoders (OBS included) handle poorly.
# -g:               frequent keyframes so OBS shows a picture quickly after (re)connecting.
exec ffmpeg -nostdin -hide_banner -nostats -loglevel "$LOG_LEVEL" \
  "${input[@]}" \
  -an "${encoder[@]}" -pix_fmt yuv420p \
  -g "$((FRAMERATE * KEYFRAME_SECONDS))" \
  -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BITRATE" \
  -f mpegts "srt://127.0.0.1:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316"
EOF
  chmod 0755 "$CAMERA_BIN"
}

install_services() {
  step "Installing services"
  write_config
  write_camera_script
  ok "Settings saved to $CONFIG_FILE"

  cat >"$UNIT_DIR/mediamtx.service" <<EOF
[Unit]
Description=MediaMTX media server (serves the camera over SRT)
After=network.target
StartLimitIntervalSec=0

[Service]
User=$RUN_USER
ExecStart=$MEDIAMTX_BIN $MEDIAMTX_CONF
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat >"$UNIT_DIR/srt-camera.service" <<EOF
[Unit]
Description=USB webcam to SRT stream (publishes to MediaMTX)
Wants=mediamtx.service
After=mediamtx.service
StartLimitIntervalSec=0

[Service]
User=$RUN_USER
SupplementaryGroups=video
ExecStart=$CAMERA_BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --quiet mediamtx.service srt-camera.service
  systemctl restart mediamtx.service srt-camera.service
  ok "mediamtx and srt-camera are running and will start on every boot"
}

verify_stream() {
  step "Testing the stream"
  local url="srt://127.0.0.1:${SRT_PORT}?streamid=read:${STREAM_NAME}"
  local probe= frames fps codec width height try

  for try in 1 2 3 4 5 6; do
    sleep 3
    probe=$(timeout 10 ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name,width,height -of csv=p=0 "$url" </dev/null 2>/dev/null || true)
    [[ -z $probe ]] || break
  done

  if [[ -z $probe ]]; then
    warn "No video is arriving yet. Recent camera log:"
    journalctl -u srt-camera -n 15 --no-pager -o cat 2>/dev/null | sed 's/^/        /' || true
    note "Fix the problem above, then run:  sudo systemctl restart srt-camera"
    return 0
  fi
  STREAM_OK=1
  IFS=, read -r codec width height <<<"$probe"
  ok "Receiving ${codec^^} ${width}x${height} from MediaMTX"

  # Count frames over 5 seconds to catch an overloaded CPU or a camera
  # that lowers its frame rate in dim light.
  frames=$(timeout 20 ffmpeg -nostdin -v error -i "$url" -t 5 -c copy -f null - -progress pipe:1 2>/dev/null \
    | awk -F= '$1 == "frame" { n = $2 } END { print n + 0 }' || true)
  fps=$(( ${frames:-0} / 5 ))
  if (( fps * 10 >= FRAMERATE * 9 )); then
    ok "Measured about $fps fps (target $FRAMERATE)"
  else
    warn "Measured only about $fps fps (target $FRAMERATE). Either:"
    note "- the Pi can't encode fast enough: set PRESET=\"ultrafast\" or a lower VIDEO_SIZE, or"
    note "- the camera slows down in dim light: add light or lower FRAMERATE."
    note "Edit $CONFIG_FILE, then: sudo systemctl restart srt-camera"
  fi
}

configure_network() {
  (( SKIP_NETWORK )) && return 0
  step "Network"
  if ! command -v nmcli >/dev/null || ! nmcli -t -f RUNNING general >/dev/null 2>&1; then
    warn "NetworkManager isn't running, so network settings were skipped."
    note "Give the Pi a fixed address with a DHCP reservation in your router instead."
    return 0
  fi

  local iface con type method cidr gw
  iface=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  if [[ -z $iface ]]; then
    warn "No default network route found; skipping network settings."
    return 0
  fi
  con=$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null || true)
  if [[ -z $con ]]; then
    warn "$iface isn't managed by NetworkManager; skipping network settings."
    return 0
  fi
  type=$(nmcli -g connection.type connection show "$con")
  method=$(nmcli -g ipv4.method connection show "$con")
  cidr=$(ip -4 -o addr show dev "$iface" | awk '{ print $4; exit }')
  gw=$(ip -4 route show default dev "$iface" | awk '{ print $3; exit }')
  NODE_IP=${cidr%/*}
  ok "Connected via $iface (\"$con\") at $cidr"

  if [[ $type == 802-11-wireless ]]; then
    # Wi-Fi power saving lets the radio doze between packets, which shows up in
    # OBS as stutter and dropped SRT packets.
    if confirm "Turn off Wi-Fi power saving? (recommended, prevents stutter)" y; then
      nmcli connection modify "$con" 802-11-wireless.powersave 2
      iw dev "$iface" set power_save off 2>/dev/null || true
      ok "Wi-Fi power saving disabled"
    fi
    note "Tip: Ethernet is more reliable than Wi-Fi for a steady $BITRATE stream."
  fi

  if [[ -z $STATIC_IP ]]; then
    if [[ $method == manual ]]; then
      ok "Already using a static IP"
      return 0
    fi
    if (( ! INTERACTIVE )); then
      note "Keeping DHCP (pass --static-ip to set a static address)."
      return 0
    fi
    note "OBS needs a fixed address for the Pi. Either reserve $NODE_IP for this Pi in your"
    note "router's DHCP settings, or set a static IP here (ideally outside the router's DHCP range)."
    confirm "Set a static IP now?" y || return 0
    ask STATIC_IP "Static IP with prefix" "$cidr"
    ask GATEWAY "Gateway (your router's IP)" "$gw"
    ask DNS "DNS server" "$DNS"
  fi

  [[ $STATIC_IP == */* ]] || STATIC_IP+=/${cidr#*/}
  [[ $STATIC_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
    || die "Invalid static IP '$STATIC_IP' (expected e.g. 192.168.1.50/24)."
  GATEWAY=${GATEWAY:-$gw}
  nmcli connection modify "$con" ipv4.method manual \
    ipv4.addresses "$STATIC_IP" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS"
  if [[ ${STATIC_IP%/*} != "$NODE_IP" ]]; then
    NEEDS_REBOOT=1
  fi
  NODE_IP=${STATIC_IP%/*}
  ok "Static IP $STATIC_IP saved for \"$con\" (fully applies after the next reboot)"
}

summary() {
  local ip=${NODE_IP:-$(hostname -I 2>/dev/null | awk '{ print $1 }')}
  local url="srt://${ip:-YOUR_PI_IP}:${SRT_PORT}?streamid=read:${STREAM_NAME}"

  echo
  if (( STREAM_OK )); then
    printf '%s%sAll done - your camera is streaming.%s\n' "$BOLD" "$GREEN" "$RESET"
  else
    printf '%s%sInstalled, but the stream is not working yet (see the log above).%s\n' "$BOLD" "$YELLOW" "$RESET"
  fi
  cat <<EOF

${BOLD}Add the camera in OBS (on your streaming PC):${RESET}
  1. Sources -> + -> Media Source, then uncheck "Local File"
  2. Input:              ${CYAN}${url}${RESET}
  3. Network Buffering:  1 MB, then OK

${BOLD}Useful commands:${RESET}
  systemctl status mediamtx srt-camera    service status
  journalctl -u srt-camera -f             live camera log
  sudo nano $CONFIG_FILE        change resolution, bitrate, etc.
  sudo systemctl restart srt-camera       apply changed settings
EOF

  if [[ $PI_MODEL == *"Pi 4"* && $ENCODER == libx264 ]]; then
    echo
    note "Pi 4 tip: if 1080p stutters, set PRESET=\"ultrafast\" or ENCODER=\"h264_v4l2m2m\""
    note "(hardware encoder) in $CONFIG_FILE."
  fi

  if (( NEEDS_REBOOT )); then
    echo
    warn "Reboot to switch to the static IP, then reconnect with:  ssh $RUN_USER@$NODE_IP"
    if (( INTERACTIVE )) && confirm "Reboot now?" y; then
      reboot
    fi
  fi
}

uninstall() {
  require_root
  step "Removing Pi SRT Stream Node"
  systemctl disable --now srt-camera.service mediamtx.service >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/srt-camera.service" "$UNIT_DIR/mediamtx.service" "$CAMERA_BIN" "$MEDIAMTX_BIN"
  systemctl daemon-reload
  ok "Removed services and binaries"
  if (( PURGE )); then
    rm -f "$CONFIG_FILE" "$MEDIAMTX_CONF"
    ok "Removed $CONFIG_FILE and $MEDIAMTX_CONF"
  else
    ok "Kept $CONFIG_FILE and $MEDIAMTX_CONF (add --purge to delete them)"
  fi
  note "ffmpeg and v4l-utils are still installed, and network settings were not changed."
}

main() {
  parse_args "$@"
  if [[ $ACTION == uninstall ]]; then
    uninstall
    return
  fi
  preflight
  load_settings
  install_packages
  choose_camera
  choose_mode
  review_settings
  install_mediamtx
  install_services
  verify_stream
  configure_network
  summary
}

main "$@"
