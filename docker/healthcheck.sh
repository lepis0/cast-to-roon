#!/bin/sh
# Healthy = Icecast answers AND the FLAC mount has a live source attached.
# Icecast only lists a mount in status-json.xsl while a source is connected, so
# a dead ffmpeg shows up here even though Icecast itself is still fine.
set -e

PORT="${ICECAST_PORT:-8000}"
MOUNT="${MOUNT_FLAC:-/cast.flac}"
# The entrypoint's normalization does not reach this process - it runs on its
# own, straight from the image environment.
case "$MOUNT" in /*) ;; *) MOUNT="/$MOUNT" ;; esac

STATUS=$(curl -fsS --max-time 4 "http://127.0.0.1:${PORT}/status-json.xsl" 2>/dev/null) || {
  echo "Icecast is not answering on port ${PORT}"
  exit 1
}

case "$STATUS" in
  *"$MOUNT"*) exit 0 ;;
  *)
    echo "no source connected to ${MOUNT}"
    exit 1
    ;;
esac
