# cast-to-roon

Turn any Google Cast / AirPlay 2 / Spotify Connect receiver into a Roon-playable
internet radio station.

A Cast receiver (an [Arylic LP10](https://www.arylic.com/) or an old Chromecast
Audio) takes the stream from your phone and puts it out on its analog line-out.
This container captures that line-in with ffmpeg, encodes it to FLAC, and serves
it from a built-in Icecast server. Add the stream URL to Roon as an internet
radio station and Roon's multiroom handles distribution to every zone.

```
[Phone: Yle Areena, Spotify, ...]
        │ Google Cast / AirPlay 2 (over the network)
        ▼
   Arylic LP10  ──cable──▶  Line In on the Docker host
                                  │  --device /dev/snd
                                  ▼
                    ┌─────────────────────────────┐
                    │  cast-to-roon container     │
                    │  ffmpeg (ALSA → FLAC)       │
                    │        ↓                    │
                    │  Icecast :8000              │
                    └─────────────────────────────┘
                                  │  http://host:8000/cast.flac
                                  ▼
                       Roon  →  every zone in the house
```

Full background and hardware notes are in [`CLAUDE.md`](./CLAUDE.md) (Finnish).

## Features

- Lossless FLAC (in Ogg) stream, plus an MP3 320k fallback mount
- Single container: Icecast + ffmpeg, supervised, with automatic encoder restart
- No hardware needed to get started — `SOURCE_MODE=tone` or `file` produces a
  test stream so you can wire up Roon before the Cast receiver arrives
- Docker healthcheck that goes unhealthy when the encoder loses its source
- Multi-arch image (amd64 + arm64), so the same image runs on Unraid or on a
  Raspberry Pi sitting next to the receiver
- PUID/PGID support for Unraid-style permission handling

## Quick start (no hardware yet)

```bash
docker run -d \
  --name cast-to-roon \
  -p 8000:8000 \
  -e SOURCE_MODE=tone \
  -e ICECAST_SOURCE_PASSWORD=secret1 \
  -e ICECAST_ADMIN_PASSWORD=secret2 \
  ghcr.io/lepis0/cast-to-roon:latest
```

Open `http://<host>:8000` for the Icecast status page, then add
`http://<host>:8000/cast.flac` to Roon (Browse → Live Radio → Add Station).
A 440 Hz tone means the whole chain works. See [`docs/roon.md`](./docs/roon.md).

Swap `SOURCE_MODE=tone` for `SOURCE_MODE=file` with a real album mounted at
`/config/test.flac` if you would rather test with music.

## With the capture hardware

```bash
docker run -d \
  --name cast-to-roon \
  -p 8000:8000 \
  --device /dev/snd \
  -v /mnt/user/appdata/cast-to-roon:/config \
  -e SOURCE_MODE=alsa \
  -e ALSA_DEVICE=hw:0,0 \
  -e ICECAST_SOURCE_PASSWORD=secret1 \
  -e ICECAST_ADMIN_PASSWORD=secret2 \
  -e TZ=Europe/Helsinki \
  ghcr.io/lepis0/cast-to-roon:latest
```

`ALSA_DEVICE` is the part you have to get right — see
[`docs/unraid.md`](./docs/unraid.md), or run `./scripts/find-line-in.sh -m` to
list capture devices and measure which one actually carries signal.
[`docker-compose.yml`](./docker-compose.yml) has the same thing in compose form,
and [`unraid/cast-to-roon.xml`](./unraid/cast-to-roon.xml) is an Unraid
container template.

## Configuration

All settings are environment variables. Everything has a default; in practice
you only need to set the two passwords and `ALSA_DEVICE`.

### Source

| Variable               | Default        | Purpose                                                     |
| ---------------------- | -------------- | ----------------------------------------------------------- |
| `SOURCE_MODE`          | `alsa`         | `alsa` (capture), `tone` (test signal), `file` (loop a file) |
| `ALSA_DEVICE`          | `hw:0,0`       | ALSA capture device, `alsa` mode only                        |
| `SAMPLE_RATE`          | `48000`        | Capture sample rate in Hz                                    |
| `SAMPLE_FORMAT`        | `s16`          | Capture sample format: `s16` or `s32`                        |
| `CHANNELS`             | `2`            | Capture channel count                                        |
| `TEST_FILE`            | `/config/test.flac` | File looped in `file` mode                              |
| `TONE_FREQUENCY`       | `440`          | Test tone frequency in `tone` mode                           |
| `TONE_VOLUME`          | `0.1`          | Test tone level (1.0 = full scale)                           |
| `AUDIO_FILTER`         | _(empty)_      | ffmpeg `-af` filter chain, e.g. `volume=2.0,highpass=f=20`   |
| `AMIXER_INIT`          | _(empty)_      | `;`-separated amixer commands applied at startup, e.g. `sset 'Line' 80% unmute;sset 'Capture' 60% cap` |
| `AMIXER_CARD`          | `0`            | Card number `AMIXER_INIT` applies to                          |
| `SOURCE_RESTART_DELAY` | `5`            | Seconds to wait before restarting a dead encoder             |
| `FFMPEG_LOG_LEVEL`     | `warning`      | ffmpeg verbosity                                             |

### Stream

| Variable              | Default               | Purpose                                    |
| --------------------- | --------------------- | ------------------------------------------ |
| `MOUNT_FLAC`          | `/cast.flac`          | FLAC mount point — the one to give to Roon |
| `MOUNT_MP3`           | `/cast.mp3`           | MP3 fallback mount point                   |
| `ENABLE_MP3`          | `true`                | Set to `false` to skip MP3 encoding        |
| `MP3_BITRATE`         | `320k`                | MP3 bitrate                                |
| `STATION_NAME`        | `Cast to Roon`        | Station name shown by players              |
| `STATION_DESCRIPTION` | `Google Cast bridge`  | Station description                        |
| `STATION_GENRE`       | `Various`             | Station genre                              |

### Icecast

| Variable                   | Default      | Purpose                                                     |
| -------------------------- | ------------ | ----------------------------------------------------------- |
| `ICECAST_PORT`             | `8000`       | HTTP port                                                    |
| `ICECAST_SOURCE_PASSWORD`  | `change-me`  | Source password. **Change it.** `A-Z a-z 0-9 . _ -` only     |
| `ICECAST_ADMIN_PASSWORD`   | `change-me`  | Admin password. **Change it.**                               |
| `ICECAST_ADMIN_USER`       | `admin`      | Admin username                                               |
| `ICECAST_MAX_CLIENTS`      | `10`         | Max simultaneous listeners                                   |
| `ICECAST_HOSTNAME`         | `localhost`  | Hostname Icecast advertises in stream URLs                   |
| `ICECAST_LOG_LEVEL`        | `3`          | 1 = error … 4 = debug                                        |
| `ICECAST_CONFIG_OVERRIDE`  | _(empty)_    | Path to a hand-written `icecast.xml`, e.g. `/config/icecast.xml` |

### Container

| Variable    | Default | Purpose                                                          |
| ----------- | ------- | ---------------------------------------------------------------- |
| `PUID`      | `0`     | User to run as. Default is root, because `/dev/snd` is `root:audio` |
| `PGID`      | `0`     | Group to run as                                                   |
| `AUDIO_GID` | `29`    | Host's `audio` group GID, used when `PUID` is non-root            |
| `TZ`        | _(UTC)_ | Timezone, e.g. `Europe/Helsinki`                                  |

## Releases

Pushes to `main` publish `ghcr.io/lepis0/cast-to-roon:edge`. Pushing a
`vX.Y.Z` tag publishes `:X.Y.Z`, `:X.Y`, `:X` and moves `:latest`, then opens a
GitHub release. Cut one with:

```bash
./scripts/release.sh patch
```

## A word on where to run it

Capture needs a host whose kernel has sound card drivers. That rules out
**Unraid**, whose kernel ships the ALSA core and nothing else — neither the
onboard Line In nor a USB sound card can be used there. The container still runs
on Unraid in `tone`/`file` mode, which is enough to set up the Roon side, but
real capture wants a Raspberry Pi (or any other Linux box) next to the Cast
receiver. See [`docs/raspberry-pi.md`](./docs/raspberry-pi.md).

## Documentation

- [`docs/raspberry-pi.md`](./docs/raspberry-pi.md) — the capture host setup:
  hardware, install, levels
- [`docs/unraid.md`](./docs/unraid.md) — sound card passthrough, finding the
  capture device, setting input levels, and the kernel caveat above
- [`docs/roon.md`](./docs/roon.md) — adding the station to Roon and grouping zones
- [`docs/troubleshooting.md`](./docs/troubleshooting.md) — no signal, dropouts,
  Roon refusing the stream
- [`CLAUDE.md`](./CLAUDE.md) — the original project spec (Finnish)

## License

MIT
