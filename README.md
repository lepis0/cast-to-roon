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
| `SAMPLE_RATE`          | `48000`        | Capture sample rate in Hz, or `auto` to measure it (see below) |
| `SAMPLE_FORMAT`        | `s16`          | Capture sample format: `s16` or `s32`                        |
| `CHANNELS`             | `2`            | Capture channel count                                        |
| `TEST_FILE`            | `/config/test.flac` | File looped in `file` mode                              |
| `TONE_FREQUENCY`       | `440`          | Test tone frequency in `tone` mode                           |
| `TONE_VOLUME`          | `0.1`          | Test tone level (1.0 = full scale)                           |
| `AUDIO_FILTER`         | _(empty)_      | ffmpeg `-af` filter chain, e.g. `volume=2.0,highpass=f=20`   |
| `RESAMPLE_ASYNC`       | `true`         | Correct ALSA clock drift with `aresample=async=1`. Set `false` only to prove it is the cause of something |
| `AMIXER_INIT`          | _(empty)_      | `;`-separated amixer commands applied at startup, e.g. `sset 'Input Source' Line;sset 'Capture' 60% cap` |
| `AMIXER_CARD`          | `0`            | Card number `AMIXER_INIT` applies to                          |
| `SOURCE_RESTART_DELAY` | `5`            | Seconds to wait before restarting a dead encoder             |
| `ALSA_PROC_DIR`        | `/proc/asound` | Where the host's ALSA proc directory is visible, `auto` rate only |
| `RATE_CANDIDATES`      | `32000 44100 48000 88200 96000` | Rates `auto` is allowed to settle on              |
| `RATE_PROBE_SECONDS`   | `6`            | Length of the `auto` rate measurement                        |
| `RATE_TOLERANCE`       | `4`            | Percent a measurement may differ from a candidate rate       |
| `RATE_WATCH_INTERVAL`  | `10`           | Seconds between mid-stream rate checks                       |

#### `SAMPLE_RATE=auto`

An S/PDIF receiver has no rate of its own - it reproduces whatever the
transmitter sends. A Cast-capable streamer changes that rate to match whatever
app is casting, so one fixed value cannot be right for all of them. Measured on
an Arylic LP10: Yle Areena sends 48 kHz, Tidal on "High" sends 44.1 kHz, and
Tidal in hi-res sends 176.4 kHz, which is past what a 96 kHz receiver can lock
to at all.

Getting it wrong is quiet. There is no error and no dropout - a source slower
than the configured rate simply plays sharp and fast, and a faster one overruns
the buffer and stutters.

`auto` measures the rate before every encoder start, by asking for a known rate
and timing how long the samples take to arrive: capturing at 48 kHz from a
44.1 kHz source takes 8.8% longer than requested. It then keeps watching, and
restarts the encoder to re-measure when the source changes rate mid-stream.

That watch reads the driver's own frame counter from `/proc/asound`, which
Docker masks by default. `runc` refuses to mount anything back onto a path
inside `/proc`, so the host directory has to go somewhere else:

```
-v /proc/asound:/host-asound:ro -e ALSA_PROC_DIR=/host-asound
```

Without it, `auto` still measures at every encoder start but cannot notice a
change mid-stream; the container says so in its log rather than doing half the
job silently. ffmpeg's own timing cannot be used for this: the ALSA input
timestamps packets from the system clock and `aresample=async` then stretches
the audio to fit, so a source that changes rate keeps reporting `speed=1x`
while quietly resampling.
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
- [`docs/unraid-vm.md`](./docs/unraid-vm.md) — the no-extra-hardware alternative:
  pass the motherboard's audio controller to a small VM
- [`docs/unraid.md`](./docs/unraid.md) — sound card passthrough, finding the
  capture device, setting input levels, and the kernel caveat above
- [`docs/roon.md`](./docs/roon.md) — adding the station to Roon and grouping zones
- [`docs/troubleshooting.md`](./docs/troubleshooting.md) — no signal, dropouts,
  Roon refusing the stream
- [`CLAUDE.md`](./CLAUDE.md) — the original project spec (Finnish)

## License

MIT
