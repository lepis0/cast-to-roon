#!/bin/sh
# Container entrypoint: normalizes configuration, renders icecast.xml, optionally
# drops privileges, then hands over to run.sh (the supervisor).
set -e

log() { echo "[cast-to-roon] $*"; }
die() { echo "[cast-to-roon] ERROR: $*" >&2; exit 1; }

log "version ${CAST_TO_ROON_VERSION:-dev}"

# ---------------------------------------------------------------- validation --

case "$SOURCE_MODE" in
  alsa|tone|file) ;;
  *) die "SOURCE_MODE must be one of: alsa, tone, file (got '$SOURCE_MODE')" ;;
esac

if [ "$SOURCE_MODE" = "alsa" ] && [ ! -d /dev/snd ]; then
  die "SOURCE_MODE=alsa but /dev/snd is missing - start the container with --device /dev/snd"
fi

if [ "$SOURCE_MODE" = "file" ] && [ ! -f "$TEST_FILE" ]; then
  die "SOURCE_MODE=file but TEST_FILE '$TEST_FILE' does not exist"
fi

case "$ICECAST_SOURCE_PASSWORD" in
  *[!A-Za-z0-9._-]*)
    # The password is embedded in an icecast:// URL for ffmpeg, where ':', '@'
    # and '/' would be parsed as URL syntax rather than as password characters.
    die "ICECAST_SOURCE_PASSWORD may only contain A-Z a-z 0-9 . _ -" ;;
esac

if [ "$ICECAST_SOURCE_PASSWORD" = "change-me" ] || [ "$ICECAST_ADMIN_PASSWORD" = "change-me" ]; then
  log "WARNING: still using the default Icecast passwords - set ICECAST_SOURCE_PASSWORD and ICECAST_ADMIN_PASSWORD"
fi

# Mount names must be absolute paths for Icecast; accept "cast.flac" too.
case "$MOUNT_FLAC" in /*) ;; *) MOUNT_FLAC="/$MOUNT_FLAC" ;; esac
case "$MOUNT_MP3"  in /*) ;; *) MOUNT_MP3="/$MOUNT_MP3" ;; esac
export MOUNT_FLAC MOUNT_MP3

# ------------------------------------------------------------ icecast config --

ICECAST_CONFIG="${ICECAST_CONFIG:-/run/cast-to-roon/icecast.xml}"
export ICECAST_CONFIG

# Escape the five XML predefined entities so a station name like "Jani & co"
# cannot produce an unparseable config.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                         -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

mkdir -p /var/log/icecast /config

if [ -n "${ICECAST_CONFIG_OVERRIDE:-}" ]; then
  [ -f "$ICECAST_CONFIG_OVERRIDE" ] || die "ICECAST_CONFIG_OVERRIDE '$ICECAST_CONFIG_OVERRIDE' does not exist"
  log "using hand-written Icecast config: $ICECAST_CONFIG_OVERRIDE"
  ICECAST_CONFIG="$ICECAST_CONFIG_OVERRIDE"
  export ICECAST_CONFIG
else
  mkdir -p "$(dirname "$ICECAST_CONFIG")"
  cat > "$ICECAST_CONFIG" <<EOF
<icecast>
    <location>$(xml_escape "${ICECAST_LOCATION:-Home}")</location>
    <admin>$(xml_escape "${ICECAST_ADMIN_EMAIL:-admin@localhost}")</admin>

    <limits>
        <clients>${ICECAST_MAX_CLIENTS}</clients>
        <sources>2</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <!-- Roon buffers before it starts decoding; bursting a chunk of the
             stream on connect makes playback start in ~1s instead of ~5s. -->
        <burst-size>131072</burst-size>
    </limits>

    <prng-seed type="profile">linux</prng-seed>

    <authentication>
        <source-password>$(xml_escape "$ICECAST_SOURCE_PASSWORD")</source-password>
        <relay-password>$(xml_escape "$ICECAST_SOURCE_PASSWORD")</relay-password>
        <admin-user>$(xml_escape "$ICECAST_ADMIN_USER")</admin-user>
        <admin-password>$(xml_escape "$ICECAST_ADMIN_PASSWORD")</admin-password>
    </authentication>

    <hostname>$(xml_escape "${ICECAST_HOSTNAME:-localhost}")</hostname>

    <listen-socket>
        <port>${ICECAST_PORT}</port>
        <bind-address>0.0.0.0</bind-address>
    </listen-socket>

    <mount type="normal">
        <mount-name>${MOUNT_FLAC}</mount-name>
        <type>application/ogg</type>
        <public>0</public>
    </mount>

    <mount type="normal">
        <mount-name>${MOUNT_MP3}</mount-name>
        <type>audio/mpeg</type>
        <public>0</public>
    </mount>

    <fileserve>1</fileserve>

    <paths>
        <basedir>/usr/share/icecast</basedir>
        <logdir>/var/log/icecast</logdir>
        <webroot>/usr/share/icecast/web</webroot>
        <adminroot>/usr/share/icecast/admin</adminroot>
        <alias source="/" destination="/status.xsl"/>
    </paths>

    <logging>
        <!-- "-" means stderr, so Icecast messages land in \`docker logs\`
             instead of a file nobody will ever read. -->
        <errorlog>-</errorlog>
        <accesslog>access.log</accesslog>
        <loglevel>${ICECAST_LOG_LEVEL}</loglevel>
        <logsize>4096</logsize>
        <logarchive>0</logarchive>
    </logging>

    <security>
        <chroot>0</chroot>
    </security>
</icecast>
EOF
fi

# ------------------------------------------------------------- privileges ----

# Default is PUID=0 (root). Unlike a typical Unraid app this container reads
# /dev/snd, whose device nodes are root:audio 0660 on the host - a non-root user
# only works if AUDIO_GID matches the host's audio group.
if [ "$PUID" = "0" ]; then
  # Icecast itself refuses to run as root, so run.sh starts it as the icecast
  # user - which means that user, and only that user, has to reach the config
  # (it holds the passwords) and the log directory.
  chgrp icecast "$ICECAST_CONFIG"
  chmod 640 "$ICECAST_CONFIG"
  chown -R icecast:icecast /var/log/icecast
  log "running as root (set PUID/PGID to drop privileges)"
  exec "$@"
fi

if ! grep -q ":${PGID}:" /etc/group; then
  addgroup -g "$PGID" castroon
fi
GROUP_NAME=$(awk -F: -v gid="$PGID" '$3==gid{print $1; exit}' /etc/group)

if ! grep -q ":${PUID}:" /etc/passwd; then
  adduser -D -H -u "$PUID" -G "$GROUP_NAME" castroon
fi
USER_NAME=$(awk -F: -v uid="$PUID" '$3==uid{print $1; exit}' /etc/passwd)

if [ "$SOURCE_MODE" = "alsa" ]; then
  if ! grep -q ":${AUDIO_GID}:" /etc/group; then
    addgroup -g "$AUDIO_GID" hostaudio
  fi
  AUDIO_GROUP=$(awk -F: -v gid="$AUDIO_GID" '$3==gid{print $1; exit}' /etc/group)
  addgroup "$USER_NAME" "$AUDIO_GROUP" 2>/dev/null || true
  log "added ${USER_NAME} to group ${AUDIO_GROUP} (gid ${AUDIO_GID}) for /dev/snd access"
fi

log "starting as ${USER_NAME}:${GROUP_NAME} (${PUID}:${PGID})"
chown -R "$PUID:$PGID" /config /var/log/icecast "$(dirname "$ICECAST_CONFIG")"
# Not root any more, so Icecast runs as this user rather than the icecast one.
chown "$PUID:$PGID" "$ICECAST_CONFIG"
chmod 600 "$ICECAST_CONFIG"

exec su-exec "${USER_NAME}:${GROUP_NAME}" "$@"
