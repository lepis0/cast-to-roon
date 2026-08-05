# Running on Unraid

The container needs exactly one thing from the host: read access to the ALSA
capture device that the Cast receiver's line-out is plugged into.

## 1. Check the host sees a sound card

From an Unraid terminal:

```bash
cat /proc/asound/cards
ls -l /dev/snd/
```

You should see the onboard codec (on an ASUS TUF GAMING B550-PLUS that is the
Realtek ALC S1200A, usually reported as `HD-Audio Generic`) and a `/dev/snd`
tree containing `controlC0`, `pcmC0D0c` and friends. The `c` suffix means
capture — no `*c` device means the card exposes no inputs.

If `/proc/asound/cards` is empty:

- onboard audio may be disabled in the BIOS — enable it
- the audio device may be bound to `vfio-pci` for a VM passthrough — check
  Settings → VM Manager → PCI Devices and unbind it
- Unraid loads `snd-hda-intel` automatically; `lsmod | grep snd` should list it

## 2. Find the right capture device

Sound cards expose several capture devices (line-in, mic, HDMI capture, a
loopback). From the repo:

```bash
./scripts/find-line-in.sh -m
```

That pulls the image, lists every capture device with `arecord -l`, then records
3 seconds from each and prints the peak level. Play music through the LP10 while
it runs:

- around `-91 dB` → silence, wrong device (or the input is muted)
- `-30 dB` … `-6 dB` → this is the one
- `0 dB` → clipping, turn the receiver's output down

`arecord -l` output like `card 0: Generic [HD-Audio Generic], device 0: ALC1220
Analog [ALC1220 Analog]` means `ALSA_DEVICE=hw:0,0`.

Note the physical port too: use the **light blue Line In**, not the pink Mic In.
Mic In applies 20 dB of boost and is mono on many codecs.

## 3. Set capture levels

Onboard Realtek codecs often boot with the capture switch muted. Check with:

```bash
docker exec -it cast-to-roon amixer -c 0
```

Look for a `Line` or `Capture` control with `[off]`. Fix it, and make it stick
across reboots with the `AMIXER_INIT` variable rather than by hand — Unraid does
not persist ALSA mixer state:

```
AMIXER_INIT=sset 'Line' 80% unmute;sset 'Capture' 60% cap
```

The commands are passed to `amixer -c $AMIXER_CARD` on every container start,
before the encoder is launched.

## 4. Add the container

Either import [`unraid/cast-to-roon.xml`](../unraid/cast-to-roon.xml) as a
template (Docker → Add Container → Template), or fill the form in manually:

| Field         | Value                                        |
| ------------- | -------------------------------------------- |
| Repository    | `ghcr.io/lepis0/cast-to-roon:latest`         |
| Network Type  | Bridge                                       |
| Port          | `8000` → `8000` (TCP)                        |
| Path          | `/mnt/user/appdata/cast-to-roon` → `/config` |
| Device        | `/dev/snd`                                   |
| Variable      | `ALSA_DEVICE` = `hw:0,0`                     |
| Variable      | `ICECAST_SOURCE_PASSWORD` = something secret |
| Variable      | `ICECAST_ADMIN_PASSWORD` = something else    |

The **Device** field is the one Unraid's basic view hides — switch the template
editor to Advanced View to get it.

## 5. Verify

```bash
docker logs cast-to-roon
curl -s http://localhost:8000/status-json.xsl | head -c 400
```

The log should end with `stream ready: ...` and the status JSON should list
`/cast.flac`. `docker ps` should show the container as `healthy` within ~30 s;
the healthcheck fails whenever the encoder loses its source, which makes an
unplugged cable visible in the Unraid dashboard.

## Updating

The image is rebuilt on every release and `:latest` moves with it, so
Watchtower (or Unraid's own update check) picks it up like any other container.

## Running on a Raspberry Pi instead

Same image — it is built for arm64 as well. If the LP10 ends up too far from
the Unraid box, run it on an RPi next to the receiver with a USB sound card:

```bash
docker run -d --name cast-to-roon -p 8000:8000 --device /dev/snd \
  -e ALSA_DEVICE=hw:1,0 ghcr.io/lepis0/cast-to-roon:latest
```

A USB capture device is normally `hw:1,0` because the Pi's own HDMI/headphone
card takes `hw:0`.
