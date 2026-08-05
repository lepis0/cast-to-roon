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
- `Cannot get card index for 0` together with the above — ALSA sees no card at
  that index at all, which is a host problem, not a wrong device number. See
  [the next section](#no-sound-card-in-the-container).
- `Device or resource busy` — something else on the host already has the card
  open. Only one process can capture at a time.
- `Permission denied` — you set a non-root `PUID` but `AUDIO_GID` does not match
  the host's `audio` group. Check with `getent group audio` on the host, or just
  run as root (`PUID=0`, the default).
- HTTP `401` from Icecast — mismatched source password, which usually means a
  stale `ICECAST_CONFIG_OVERRIDE` file in `/config`.

## No sound card in the container

Symptom: `Cannot get card index for 0` and `cannot open audio device hw:0,0
(No such file or directory)`, or the container refusing to start with "no
capture devices are visible in the container".

Work outwards from the host:

```bash
# 1. On the host - does the kernel see a card at all?
cat /proc/asound/cards
ls -l /dev/snd/
```

**`/proc/asound/cards` is empty, or `/dev/snd` only holds `seq` and `timer`.**
No sound card driver is active. First find out whether the driver exists at all:

```bash
ls /lib/modules/$(uname -r)/kernel/sound/
```

*No `pci/` or `usb/` directory, only `core/`* — the kernel was built without
sound card drivers, so there is nothing to load and a USB sound card will not
help either. This is the situation on Unraid; run the capture on another
machine, see [raspberry-pi.md](./raspberry-pi.md).

*The modules are there* — they just are not loaded:

```bash
modprobe snd-hda-intel          # onboard
modprobe snd-usb-audio          # USB sound card
cat /proc/asound/cards          # should now list the card
```

Persist it in `/etc/modules` (Debian/Pi OS) or, on Unraid, `/boot/config/go`
above the `emhttp` line. If `modprobe` reports the module as missing despite the
file existing, run `depmod -a` first. If the card is still absent, it is either
disabled in the BIOS or bound to `vfio-pci` for VM passthrough — check
Settings → VM Manager → PCI Devices.

**The host lists a card but the container still cannot see it.** `--device
/dev/snd` maps the device nodes that existed *at container creation time*, so a
card that appeared after the container was created is invisible to it. Recreate
the container (Unraid: Edit → Apply is enough, it recreates):

```bash
docker exec cast-to-roon ls -l /dev/snd/    # what the container actually has
```

You want `pcmC0D0c`-style nodes in there; the trailing `c` is capture. Nodes
ending in `p` are playback only and cannot be recorded from.

**Both look right but `hw:0,0` still fails.** The card index is not 0, or device
0 of that card has no capture stream. List them properly:

```bash
docker exec cast-to-roon arecord -l
```

Card names are more stable than indexes across reboots, so prefer
`ALSA_DEVICE=hw:CARD=Generic,DEV=0` over `hw:0,0` once you know which one works.

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
