#!/usr/bin/env bash
# Finds the right ALSA capture device on a Docker host (Unraid has no
# alsa-utils of its own, so everything runs inside the container image).
#
#   ./scripts/find-line-in.sh          # list capture devices
#   ./scripts/find-line-in.sh -m       # also measure 3s of signal per device
#
# Play music through the LP10 while measuring: a device sitting at -91 dB is
# silence, anything around -30..-6 dB is a real signal.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/lepis0/cast-to-roon:latest}"
MEASURE=0
[ "${1:-}" = "-m" ] && MEASURE=1

run() { docker run --rm --device /dev/snd --entrypoint "$1" "$IMAGE" "${@:2}"; }

echo "== capture devices =="
run arecord -l

if [ "$MEASURE" = "0" ]; then
  echo
  echo "Re-run with -m to measure the signal level on each device."
  exit 0
fi

echo
echo "== signal levels (3s per device) =="
# `arecord -l` prints lines like: "card 0: Generic [HD-Audio Generic], device 0: ..."
run arecord -l | awk '/^card /{gsub(":","",$2); gsub(":","",$6); print $2","$6}' |
while IFS=, read -r card device; do
  dev="hw:${card},${device}"
  printf '%-12s ' "$dev"
  level=$(docker run --rm --device /dev/snd --entrypoint ffmpeg "$IMAGE" \
            -hide_banner -nostdin -loglevel info \
            -f alsa -channels 2 -sample_rate 48000 -sample_fmt s16 -i "$dev" \
            -t 3 -af volumedetect -f null - 2>&1 |
          grep -Eo 'max_volume: -?[0-9.]+ dB' | head -n1) || true
  echo "${level:-could not read from this device}"
done
