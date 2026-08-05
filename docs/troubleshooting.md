# Troubleshooting

Start here, always:

```bash
docker logs --tail 50 cast-to-roon
curl -s http://localhost:8000/status-json.xsl
```

## Startup warnings you can ignore

Two Icecast warnings show up on every start and neither affects playback:

- `<hostname> not configured, using default value "localhost"` — Icecast only
  needs a real hostname for public YP directory listings, which this stream does
  not use. Set `ICECAST_HOSTNAME` to your host's IP if you want it gone.
- `Unsupported or legacy stream type: "audio/mpeg"` — Icecast 2.5 saying MP3 is
  a legacy format. The `/cast.mp3` fallback mount works regardless; set
  `ENABLE_MP3=false` if you only ever use FLAC.

## The container restarts in a loop

The entrypoint refuses to start on a misconfiguration and says why. The common
ones:

| Message                                             | Fix                                                        |
| --------------------------------------------------- | ---------------------------------------------------------- |
| `/dev/snd is missing`                                | Add `--device /dev/snd` (Unraid: Device field, Advanced View) |
| `TEST_FILE ... does not exist`                       | Mount the file, or switch back to `SOURCE_MODE=tone`         |
| `ICECAST_SOURCE_PASSWORD may only contain ...`       | Use only `A-Z a-z 0-9 . _ -` — the password goes into a URL  |
| `Icecast did not come up within 30s`                 | Port conflict on `ICECAST_PORT`, or a bad `ICECAST_CONFIG_OVERRIDE` |

## The encoder restarts every few seconds

The log will show `encoder exited (code N), restarting in 5s` in a loop. Raise
the detail level with `FFMPEG_LOG_LEVEL=info` and read the actual ffmpeg error.

- `cannot open audio device hw:0,0: No such file or directory` — wrong
  `ALSA_DEVICE`. Run `./scripts/find-line-in.sh` and pick from the list.
- `Device or resource busy` — something else on the host already has the card
  open. Only one process can capture at a time.
- `Permission denied` — you set a non-root `PUID` but `AUDIO_GID` does not match
  the host's `audio` group. Check with `getent group audio` on the host, or just
  run as root (`PUID=0`, the default).
- HTTP `401` from Icecast — mismatched source password, which usually means a
  stale `ICECAST_CONFIG_OVERRIDE` file in `/config`.

## The stream exists but is silent

The mount is up, Roon plays, nothing comes out. Measure the input:

```bash
./scripts/find-line-in.sh -m
```

- Everything reads `-91 dB` while music is casting → the capture path is muted
  or you are on the wrong device. See [unraid.md](./unraid.md) step 3.
- The measurement shows signal but Roon is silent → you are probably listening
  to the wrong mount, or Roon's volume/zone is muted.
- Signal is there but very quiet → raise the receiver's output level first, then
  the ALSA capture level (`AMIXER_INIT`), and only as a last resort apply
  `AUDIO_FILTER=volume=2.0`. Amplifying digitally after capture raises the noise
  floor with it.

## Distortion or clipping

Peak measurement at `0 dB` means the ADC is clipping. Turn the LP10's output
down (its app has an output level setting) rather than attenuating in software —
by the time it reaches ffmpeg, the clipped samples are already lost.

## Hum or buzz

Analog problem, not a software one: ground loop between the receiver and the
host. A ground loop isolator on the RCA/3.5 mm line (~10 €) fixes it. If the
receiver has optical S/PDIF out and the capture side has optical in, that path
avoids the issue entirely.

## Dropouts in Roon

- Check `docker logs` for encoder restarts — that is a source problem, not a
  network one.
- Wired Ethernet to the Cast receiver beats mesh WiFi; roaming between mesh APs
  interrupts the cast itself, which the bridge cannot fix.
- If Icecast logs `client timeout`, the network path between the host and Roon
  Core is dropping. Raising `ICECAST_MAX_CLIENTS` does not help here — Roon is a
  single client.

## The phone cannot see the Cast receiver

Nothing to do with this container: Google Cast discovery is mDNS, so the phone
and the receiver must be on the same subnet with client isolation off. On a
segmented UniFi network, enable the mDNS reflector.

## Getting a clean state

```bash
docker rm -f cast-to-roon
rm -rf /mnt/user/appdata/cast-to-roon    # only holds test files / overrides
```

The generated `icecast.xml` lives in `/run` inside the container and is rebuilt
from environment variables on every start, so there is no stale config to clear
unless you set `ICECAST_CONFIG_OVERRIDE` yourself.
