#!/bin/sh
# Supervisor: runs Icecast and the ffmpeg encoder side by side, restarts the
# encoder if it dies (e.g. the LP10 is unplugged), and shuts both down cleanly
# on SIGTERM from `docker stop`.
set -e

RUN_DIR=/run/cast-to-roon
FFMPEG_PID_FILE="$RUN_DIR/ffmpeg.pid"
mkdir -p "$RUN_DIR"

log() { echo "[cast-to-roon] $*"; }

ICECAST_PID=""
SOURCE_PID=""
SHUTTING_DOWN=0

# shutdown [exit-code] - 0 when asked to stop, 1 when something died on us.
shutdown() {
  [ "$SHUTTING_DOWN" = "1" ] && return 0
  SHUTTING_DOWN=1
  log "shutting down"

  # Kill the restart loop first, otherwise it would helpfully start a new
  # encoder right after we kill the current one.
  if [ -n "$SOURCE_PID" ]; then kill "$SOURCE_PID" 2>/dev/null || true; fi
  if [ -f "$FFMPEG_PID_FILE" ]; then kill "$(cat "$FFMPEG_PID_FILE")" 2>/dev/null || true; fi
  if [ -n "$ICECAST_PID" ]; then kill "$ICECAST_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  exit "${1:-0}"
}
trap shutdown TERM INT

# Interruptible sleep: a plain `sleep` blocks signal delivery until it returns,
# which would make `docker stop` wait for the full timeout.
nap() { sleep "$1" & wait $! 2>/dev/null || true; }

# ------------------------------------------------------------------ icecast --

log "starting Icecast on port ${ICECAST_PORT} (config: ${ICECAST_CONFIG})"
if [ "$(id -u)" = "0" ]; then
  # Icecast exits with "You should not run icecast2 as root". The container as a
  # whole stays root for /dev/snd, only Icecast is dropped - it has no business
  # touching the sound card anyway.
  su-exec icecast:icecast icecast -c "$ICECAST_CONFIG" &
else
  icecast -c "$ICECAST_CONFIG" &
fi
ICECAST_PID=$!

i=0
until curl -fsS -o /dev/null "http://127.0.0.1:${ICECAST_PORT}/status.xsl" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then
    log "ERROR: Icecast did not come up within 30s"
    shutdown 1
  fi
  if ! kill -0 "$ICECAST_PID" 2>/dev/null; then
    log "ERROR: Icecast exited during startup"
    shutdown 1
  fi
  nap 1
done
log "Icecast is up"

# ------------------------------------------------------------- mixer setup --

# ALSA mixer state is not persisted across host reboots on Unraid, so a capture
# switch you unmuted by hand can come back muted. AMIXER_INIT re-applies the
# settings on every container start, e.g.
#   AMIXER_INIT=sset 'Line' 80% unmute;sset 'Capture' 60% cap
if [ "$SOURCE_MODE" = "alsa" ] && [ -n "${AMIXER_INIT:-}" ]; then
  echo "$AMIXER_INIT" | tr ';' '\n' | while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    log "amixer -c ${AMIXER_CARD:-0} ${cmd}"
    # eval, so quoted control names like 'Line Boost' stay one argument. The
    # value comes from the container's own configuration, same trust level as
    # ALSA_DEVICE or AUDIO_FILTER.
    eval "amixer -c ${AMIXER_CARD:-0} ${cmd}" >/dev/null 2>&1 ||
      log "WARNING: amixer command failed: ${cmd}"
  done
fi

# ------------------------------------------------------------------ encoder --

SOURCE_URL="icecast://source:${ICECAST_SOURCE_PASSWORD}@127.0.0.1:${ICECAST_PORT}"

# MP3 tops out at 48 kHz; resample only when the capture rate exceeds that, so a
# normal 44.1/48 kHz capture is passed through untouched.
MP3_RATE="$SAMPLE_RATE"
if [ "$SAMPLE_RATE" -gt 48000 ]; then MP3_RATE=48000; fi

# Builds the full ffmpeg argument list in "$@" and runs it. Everything goes
# through positional parameters rather than a string, so values with spaces
# (STATION_NAME, TEST_FILE, ...) survive intact.
run_encoder() {
  set -- -hide_banner -nostdin -loglevel "${FFMPEG_LOG_LEVEL:-warning}"

  case "$SOURCE_MODE" in
    alsa)
      set -- "$@" -f alsa -channels "$CHANNELS" -sample_rate "$SAMPLE_RATE" \
                  -sample_fmt "$SAMPLE_FORMAT" -i "$ALSA_DEVICE"
      ;;
    tone)
      # -re throttles lavfi to real time; without it ffmpeg would generate the
      # tone as fast as the CPU allows and flood the Icecast queue. Volume and
      # channel layout live inside the filter graph so they cannot be mistaken
      # for output options.
      set -- "$@" -re -f lavfi \
        -i "sine=frequency=${TONE_FREQUENCY}:sample_rate=${SAMPLE_RATE},volume=${TONE_VOLUME},aformat=channel_layouts=stereo"
      ;;
    file)
      set -- "$@" -re -stream_loop -1 -i "$TEST_FILE"
      ;;
  esac

  # --- FLAC output (the one Roon should use) ---
  # -sample_fmt is pinned so tone/file mode produces the same bit depth as a
  # real capture instead of ffmpeg's 24-bit default.
  set -- "$@" -map 0:a -c:a flac -ar "$SAMPLE_RATE" -ac "$CHANNELS" -sample_fmt "$SAMPLE_FORMAT"
  if [ -n "${AUDIO_FILTER:-}" ]; then set -- "$@" -af "$AUDIO_FILTER"; fi
  set -- "$@" -f ogg -content_type application/ogg \
              -ice_name "$STATION_NAME" -ice_description "$STATION_DESCRIPTION" \
              -ice_genre "$STATION_GENRE" -ice_public 0 \
              "${SOURCE_URL}${MOUNT_FLAC}"

  # --- MP3 output (fallback for players without Ogg FLAC support) ---
  if [ "$ENABLE_MP3" = "true" ]; then
    set -- "$@" -map 0:a -c:a libmp3lame -b:a "$MP3_BITRATE" -ar "$MP3_RATE" -ac "$CHANNELS"
    if [ -n "${AUDIO_FILTER:-}" ]; then set -- "$@" -af "$AUDIO_FILTER"; fi
    set -- "$@" -f mp3 -content_type audio/mpeg \
                -ice_name "$STATION_NAME" -ice_description "$STATION_DESCRIPTION" \
                -ice_genre "$STATION_GENRE" -ice_public 0 \
                "${SOURCE_URL}${MOUNT_MP3}"
  fi

  exec ffmpeg "$@"
}

source_loop() {
  while true; do
    if [ "$ENABLE_MP3" = "true" ]; then
      log "starting encoder: ${SOURCE_MODE} -> ${MOUNT_FLAC} + ${MOUNT_MP3}"
    else
      log "starting encoder: ${SOURCE_MODE} -> ${MOUNT_FLAC}"
    fi
    run_encoder &
    ff=$!
    echo "$ff" > "$FFMPEG_PID_FILE"
    rc=0
    wait "$ff" || rc=$?
    rm -f "$FFMPEG_PID_FILE"
    log "encoder exited (code ${rc}), restarting in ${SOURCE_RESTART_DELAY}s"
    sleep "$SOURCE_RESTART_DELAY"
  done
}

source_loop &
SOURCE_PID=$!

log "stream ready: http://<host>:${ICECAST_PORT}${MOUNT_FLAC}"

# ------------------------------------------------------------------ monitor --

while true; do
  if ! kill -0 "$ICECAST_PID" 2>/dev/null; then
    log "ERROR: Icecast died - exiting so Docker can restart the container"
    shutdown 1
  fi
  if ! kill -0 "$SOURCE_PID" 2>/dev/null; then
    log "ERROR: encoder supervisor died - exiting so Docker can restart the container"
    shutdown 1
  fi
  nap 5
done
