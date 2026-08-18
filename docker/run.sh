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
  if [ -f "$WATCH_PID_FILE" ]; then kill "$(cat "$WATCH_PID_FILE")" 2>/dev/null || true; fi
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
#   AMIXER_INIT=sset 'Input Source' Line;sset 'Capture' 60% cap
# On Realtek HDA the capture path is 'Input Source' (which input the ADC
# listens to) plus 'Capture' (its level and switch). 'Line' there is a
# playback control - it routes line-in to the speakers and does nothing
# for recording.
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

# Newer ffmpeg deprecated the ALSA input device's "channels" option in favour of
# "ch_layout" and warns on every start. Probe which one this build wants, so the
# same script works whichever ffmpeg Alpine ships.
ALSA_CHANNEL_OPT="-channels"
ALSA_CHANNEL_VAL="$CHANNELS"
if ffmpeg -hide_banner -h demuxer=alsa 2>/dev/null | grep -q -- '-ch_layout'; then
  ALSA_CHANNEL_OPT="-ch_layout"
  case "$CHANNELS" in
    1) ALSA_CHANNEL_VAL="mono" ;;
    2) ALSA_CHANNEL_VAL="stereo" ;;
    *) ALSA_CHANNEL_VAL="${CHANNELS}c" ;;
  esac
fi

# ------------------------------------------------------------- input rate --

# SAMPLE_RATE=auto measures what the source is actually sending before each
# encoder start. It exists because an S/PDIF receiver has no rate of its own: it
# reproduces whatever the transmitter sends, and a Cast-capable streamer changes
# that rate to match whatever app is casting. Getting it wrong is quiet - the
# stream keeps running, just at the wrong pitch and speed.
RATE_AUTO=false
if [ "$SAMPLE_RATE" = "auto" ]; then
  if [ "$SOURCE_MODE" = "alsa" ]; then
    RATE_AUTO=true
  else
    log "WARNING: SAMPLE_RATE=auto only applies to SOURCE_MODE=alsa, using 48000"
    SAMPLE_RATE=48000
  fi
fi

RATE_CANDIDATES="${RATE_CANDIDATES:-32000 44100 48000 88200 96000}"
RATE_PROBE_SECONDS="${RATE_PROBE_SECONDS:-6}"
RATE_PROBE_REFERENCE="${RATE_PROBE_REFERENCE:-48000}"
RATE_TOLERANCE="${RATE_TOLERANCE:-4}"
RATE_WATCH_INTERVAL="${RATE_WATCH_INTERVAL:-10}"
WATCH_PID_FILE="$RUN_DIR/watch.pid"

# Centiseconds since boot. /proc/uptime rather than `date`, because busybox date
# has no %N and a whole second is far too coarse to measure drift with.
uptime_cs() { read -r up _ < /proc/uptime; echo "${up%.*}${up#*.}"; }

# arecord wants S16_LE where ffmpeg wants s16.
arecord_format() {
  case "$SAMPLE_FORMAT" in
    s16) echo "S16_LE" ;;
    s32) echo "S32_LE" ;;
    *)   echo "S16_LE" ;;
  esac
}

# Nearest candidate rate, or nothing if the measurement is not close to any of
# them - a wild reading means the probe was disturbed, and guessing from it
# would be worse than retrying.
snap_rate() {
  best="" bestd=""
  for r in $RATE_CANDIDATES; do
    d=$(( $1 - r ))
    [ "$d" -lt 0 ] && d=$(( -d ))
    if [ -z "$bestd" ] || [ "$d" -lt "$bestd" ]; then bestd="$d"; best="$r"; fi
  done
  [ -z "$best" ] && return 1
  [ $(( bestd * 100 / best )) -gt "$RATE_TOLERANCE" ] && return 1
  echo "$best"
}

# The device delivers samples at the transmitter's rate no matter which rate we
# ask for, so asking for a known rate and timing how long the samples take to
# arrive reveals the real one:
#     actual = asked * asked_duration / measured_duration
# Capturing at 48 kHz from a 44.1 kHz source takes 8.8% longer than requested.
detect_rate() {
  start=$(uptime_cs)
  arecord -D "$ALSA_DEVICE" -f "$(arecord_format)" -c "$CHANNELS" \
          -r "$RATE_PROBE_REFERENCE" -d "$RATE_PROBE_SECONDS" \
          /dev/null >/dev/null 2>&1 || return 1
  elapsed=$(( $(uptime_cs) - start ))
  [ "$elapsed" -le 0 ] && return 1
  snap_rate $(( RATE_PROBE_REFERENCE * RATE_PROBE_SECONDS * 100 / elapsed ))
}

# Sets ACTIVE_RATE (what we capture and encode at) and MP3_RATE. In auto mode it
# blocks until the source locks - without a signal there is no rate to measure,
# and starting the encoder anyway would only spin it in its restart loop.
set_active_rate() {
  if [ "$RATE_AUTO" != "true" ]; then
    ACTIVE_RATE="$SAMPLE_RATE"
  else
    ACTIVE_RATE=""
    while [ -z "$ACTIVE_RATE" ]; do
      ACTIVE_RATE=$(detect_rate) || ACTIVE_RATE=""
      if [ -z "$ACTIVE_RATE" ]; then
        log "no lock on ${ALSA_DEVICE} (or rate outside: ${RATE_CANDIDATES}) - retrying in ${SOURCE_RESTART_DELAY}s"
        nap "$SOURCE_RESTART_DELAY"
      fi
    done
    log "detected input rate: ${ACTIVE_RATE} Hz"
  fi

  # MP3 tops out at 48 kHz; resample only when the capture rate exceeds that, so
  # a normal 44.1/48 kHz capture is passed through untouched.
  MP3_RATE="$ACTIVE_RATE"
  if [ "$ACTIVE_RATE" -gt 48000 ]; then MP3_RATE=48000; fi
}

# Where /proc/asound is visible. Docker masks it, and runc refuses a bind mount
# back onto anything inside /proc, so the host directory has to be mounted
# somewhere else entirely and pointed at from here:
#   -v /proc/asound:/host-asound:ro -e ALSA_PROC_DIR=/host-asound
ALSA_PROC_DIR="${ALSA_PROC_DIR:-/proc/asound}"

# Status file holding the capture stream's frame counter, derived from
# ALSA_DEVICE. Handles hw:1,0 and plughw:CARD=Rx,DEV=0 alike; anything more
# exotic gets no watcher rather than a wrong one.
alsa_status_path() {
  spec="${ALSA_DEVICE#plug}"
  case "$spec" in hw:*) spec="${spec#hw:}" ;; *) return 1 ;; esac
  card="${spec%%,*}"
  dev="${spec#*,}"
  [ "$dev" = "$spec" ] && dev=0
  card="${card#CARD=}"
  dev="${dev#DEV=}"
  case "$card" in
    ''|*[!0-9]*) dir="${ALSA_PROC_DIR}/${card}" ;;
    *)           dir="${ALSA_PROC_DIR}/card${card}" ;;
  esac
  echo "${dir}/pcm${dev}c/sub0/status"
}

# Watches the rate the hardware is actually delivering, by differencing the
# driver's own frame counter. ffmpeg's own timing cannot be used for this: the
# ALSA input timestamps packets from the system clock and aresample=async then
# stretches the audio to fit, so a source that changes rate mid-stream keeps
# reporting speed=1x while quietly resampling. hw_ptr comes straight from the
# driver and no filter can paper over it.
watch_drift() {
  ff_pid="$1"
  status="$2"
  strikes=0
  last_ptr=""
  last_cs=""
  while kill -0 "$ff_pid" 2>/dev/null; do
    nap "$RATE_WATCH_INTERVAL"

    if ! grep -q '^state: RUNNING' "$status" 2>/dev/null; then
      last_ptr=""
      continue
    fi
    ptr=$(awk '/hw_ptr/ {print $3}' "$status" 2>/dev/null)
    now=$(uptime_cs)
    case "$ptr" in ''|*[!0-9]*) last_ptr=""; continue ;; esac

    # First reading after a start or a stall is only a baseline.
    if [ -z "$last_ptr" ]; then
      last_ptr="$ptr"
      last_cs="$now"
      continue
    fi
    d_frames=$(( ptr - last_ptr ))
    d_cs=$(( now - last_cs ))
    last_ptr="$ptr"
    last_cs="$now"
    if [ "$d_frames" -le 0 ] || [ "$d_cs" -le 0 ]; then continue; fi

    measured=$(( d_frames * 100 / d_cs ))
    actual=$(snap_rate "$measured") || { strikes=0; continue; }
    if [ "$actual" = "$ACTIVE_RATE" ]; then
      strikes=0
      continue
    fi

    # Two in a row, so one disturbed interval cannot restart the encoder.
    strikes=$(( strikes + 1 ))
    log "source is ${actual} Hz but encoding at ${ACTIVE_RATE} Hz (${strikes}/2)"
    if [ "$strikes" -ge 2 ]; then
      log "source rate changed - restarting encoder to re-probe"
      kill "$ff_pid" 2>/dev/null || true
      return 0
    fi
  done
}

# Builds the full ffmpeg argument list in "$@" and runs it. Everything goes
# through positional parameters rather than a string, so values with spaces
# (STATION_NAME, TEST_FILE, ...) survive intact.
run_encoder() {
  set -- -hide_banner -nostdin -loglevel "${FFMPEG_LOG_LEVEL:-warning}"

  case "$SOURCE_MODE" in
    alsa)
      set -- "$@" -f alsa "$ALSA_CHANNEL_OPT" "$ALSA_CHANNEL_VAL" \
                  -sample_rate "$ACTIVE_RATE" -sample_fmt "$SAMPLE_FORMAT" \
                  -i "$ALSA_DEVICE"
      ;;
    tone)
      # -re throttles lavfi to real time; without it ffmpeg would generate the
      # tone as fast as the CPU allows and flood the Icecast queue. Volume and
      # channel layout live inside the filter graph so they cannot be mistaken
      # for output options.
      set -- "$@" -re -f lavfi \
        -i "sine=frequency=${TONE_FREQUENCY}:sample_rate=${ACTIVE_RATE},volume=${TONE_VOLUME},aformat=channel_layouts=stereo"
      ;;
    file)
      set -- "$@" -re -stream_loop -1 -i "$TEST_FILE"
      ;;
  esac

  # --- FLAC output (the one Roon should use) ---
  # -sample_fmt is pinned so tone/file mode produces the same bit depth as a
  # real capture instead of ffmpeg's 24-bit default.
  set -- "$@" -map 0:a -c:a flac -ar "$ACTIVE_RATE" -ac "$CHANNELS" -sample_fmt "$SAMPLE_FORMAT"
  if [ -n "$FILTER_CHAIN" ]; then set -- "$@" -af "$FILTER_CHAIN"; fi
  set -- "$@" -f ogg -content_type application/ogg \
              -ice_name "$STATION_NAME" -ice_description "$STATION_DESCRIPTION" \
              -ice_genre "$STATION_GENRE" -ice_public 0 \
              "${SOURCE_URL}${MOUNT_FLAC}"

  # --- MP3 output (fallback for players without Ogg FLAC support) ---
  if [ "$ENABLE_MP3" = "true" ]; then
    set -- "$@" -map 0:a -c:a libmp3lame -b:a "$MP3_BITRATE" -ar "$MP3_RATE" -ac "$CHANNELS"
    if [ -n "$FILTER_CHAIN" ]; then set -- "$@" -af "$FILTER_CHAIN"; fi
    set -- "$@" -f mp3 -content_type audio/mpeg \
                -ice_name "$STATION_NAME" -ice_description "$STATION_DESCRIPTION" \
                -ice_genre "$STATION_GENRE" -ice_public 0 \
                "${SOURCE_URL}${MOUNT_MP3}"
  fi

  exec ffmpeg "$@"
}

# Resolved once. The watcher needs the driver's frame counter, and Docker masks
# /proc/asound by default - without it auto mode still probes at every encoder
# start but cannot notice a change mid-stream, which is worth saying out loud
# rather than silently doing half the job.
ALSA_STATUS=""
if [ "$RATE_AUTO" = "true" ]; then
  ALSA_STATUS=$(alsa_status_path) || ALSA_STATUS=""
  if [ -z "$ALSA_STATUS" ]; then
    log "WARNING: no /proc/asound path for ALSA_DEVICE=${ALSA_DEVICE} - a mid-stream rate change will not be noticed"
  elif [ ! -r "$ALSA_STATUS" ]; then
    log "WARNING: ${ALSA_STATUS} unreadable - mount the host's ALSA proc dir (-v /proc/asound:/host-asound:ro -e ALSA_PROC_DIR=/host-asound), or a mid-stream rate change will not be noticed"
    ALSA_STATUS=""
  fi
fi

source_loop() {
  while true; do
    # Blocks here until the source locks, so the encoder is only ever started
    # against a rate we have actually measured.
    set_active_rate

    if [ "$ENABLE_MP3" = "true" ]; then
      log "starting encoder: ${SOURCE_MODE} @ ${ACTIVE_RATE} Hz -> ${MOUNT_FLAC} + ${MOUNT_MP3}"
    else
      log "starting encoder: ${SOURCE_MODE} @ ${ACTIVE_RATE} Hz -> ${MOUNT_FLAC}"
    fi
    run_encoder &
    ff=$!
    echo "$ff" > "$FFMPEG_PID_FILE"

    # Only in auto mode: a fixed rate has nothing to re-probe, and restarting
    # the encoder would just land on the same wrong rate again.
    if [ "$RATE_AUTO" = "true" ] && [ -n "$ALSA_STATUS" ]; then
      watch_drift "$ff" "$ALSA_STATUS" &
      echo "$!" > "$WATCH_PID_FILE"
    fi

    rc=0
    wait "$ff" || rc=$?
    rm -f "$FFMPEG_PID_FILE"
    if [ -f "$WATCH_PID_FILE" ]; then
      kill "$(cat "$WATCH_PID_FILE")" 2>/dev/null || true
      rm -f "$WATCH_PID_FILE"
    fi
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
