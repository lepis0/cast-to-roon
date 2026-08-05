# syntax=docker/dockerfile:1

FROM alpine:3.24

# icecast     - the streaming server Roon connects to
# ffmpeg      - captures ALSA line-in and encodes FLAC/MP3 into Icecast
# alsa-utils  - arecord/amixer, for verifying the capture device from inside
#               the container (see docs/unraid.md)
# su-exec     - drops privileges to PUID/PGID when requested (see entrypoint.sh)
# mailcap     - /etc/mime.types, which Icecast warns about on every start
RUN apk add --no-cache \
      icecast \
      ffmpeg \
      alsa-utils \
      su-exec \
      mailcap \
      tzdata \
      ca-certificates \
      curl

# Icecast refuses to run as root, so it always runs as this user even when the
# rest of the container is root (which /dev/snd access normally requires).
RUN if ! getent passwd icecast >/dev/null; then \
      addgroup -S icecast && adduser -S -D -H -G icecast icecast; \
    fi

COPY docker/entrypoint.sh docker/run.sh docker/healthcheck.sh /opt/cast-to-roon/
RUN chmod +x /opt/cast-to-roon/*.sh

# Defaults are also documented in README.md - keep the two in sync.
ENV ICECAST_PORT=8000 \
    ICECAST_ADMIN_USER=admin \
    ICECAST_SOURCE_PASSWORD=change-me \
    ICECAST_ADMIN_PASSWORD=change-me \
    ICECAST_MAX_CLIENTS=10 \
    ICECAST_LOG_LEVEL=3 \
    STATION_NAME="Cast to Roon" \
    STATION_DESCRIPTION="Google Cast bridge" \
    STATION_GENRE="Various" \
    MOUNT_FLAC=/cast.flac \
    MOUNT_MP3=/cast.mp3 \
    ENABLE_MP3=true \
    MP3_BITRATE=320k \
    SOURCE_MODE=alsa \
    ALSA_DEVICE=hw:0,0 \
    SAMPLE_RATE=48000 \
    SAMPLE_FORMAT=s16 \
    CHANNELS=2 \
    TEST_FILE=/config/test.flac \
    TONE_FREQUENCY=440 \
    TONE_VOLUME=0.1 \
    SOURCE_RESTART_DELAY=5 \
    PUID=0 \
    PGID=0 \
    AUDIO_GID=29

VOLUME ["/config"]
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD /opt/cast-to-roon/healthcheck.sh

ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown
ENV CAST_TO_ROON_VERSION=${VERSION}

LABEL org.opencontainers.image.title="cast-to-roon" \
      org.opencontainers.image.description="Google Cast / AirPlay audio to a FLAC Icecast stream Roon can play" \
      org.opencontainers.image.source="https://github.com/lepis0/cast-to-roon" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}"

ENTRYPOINT ["/opt/cast-to-roon/entrypoint.sh"]
CMD ["/opt/cast-to-roon/run.sh"]
