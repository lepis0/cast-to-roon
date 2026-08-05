# Capturing on a Raspberry Pi

Use this when the machine you would rather run the container on cannot see a
sound card — which is the case on Unraid, whose kernel has no card drivers at
all (see [unraid.md](./unraid.md#unraid-kernel-has-no-sound-drivers)).

The Pi sits next to the Cast receiver and does nothing but capture and encode.
Roon still plays a single internet radio URL; only the host in that URL changes.

```
[Phone] ──cast──▶ [Arylic LP10] ──3.5mm/RCA──▶ [USB sound card] ─▶ [Pi: this container] ─▶ Roon
```

## Hardware

| Part                | Notes                                                                 |
| ------------------- | --------------------------------------------------------------------- |
| Raspberry Pi        | Zero 2 W (~20 €) is enough: FLAC encoding of one stereo stream is a few percent of one core. A 3A+/4 lying in a drawer works just as well. |
| USB sound card      | Anything USB Audio Class with a **line input** — Behringer UCA222 (~30 €) is the safe default. Avoid mic-only dongles: they are mono and apply boost. |
| microSD             | 8 GB+. The container writes almost nothing, so wear is not a concern. |
| Cable               | 3.5 mm or RCA from the LP10's line-out to the sound card's input.      |

On a Zero 2 W the sound card needs a micro-USB OTG adapter, and there is no
Ethernet port — either accept WiFi or pick a Pi with a jack.

## Install

1. Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager. Set the
   hostname, enable SSH and configure WiFi in the Imager's settings screen so
   the Pi comes up headless.

2. SSH in and install Docker:

   ```bash
   curl -fsSL https://get.docker.com | sh
   sudo usermod -aG docker "$USER"      # log out and back in afterwards
   ```

3. Plug in the sound card and confirm the kernel sees it. Unlike Unraid, Pi OS
   ships the normal driver set:

   ```bash
   arecord -l
   ```

   A USB card is normally `card 1`, because the Pi's own HDMI/headphone device
   takes `card 0` — so `ALSA_DEVICE=hw:1,0`. Disable onboard audio in
   `/boot/firmware/config.txt` (`dtparam=audio=off`) if you want the USB card to
   become `hw:0,0` and stay there.

4. Run the container:

   ```bash
   docker run -d \
     --name cast-to-roon \
     --restart unless-stopped \
     -p 8000:8000 \
     --device /dev/snd \
     -v /home/pi/cast-to-roon:/config \
     -e SOURCE_MODE=alsa \
     -e ALSA_DEVICE=hw:1,0 \
     -e ICECAST_SOURCE_PASSWORD=secret1 \
     -e ICECAST_ADMIN_PASSWORD=secret2 \
     -e TZ=Europe/Helsinki \
     ghcr.io/lepis0/cast-to-roon:latest
   ```

   `--restart unless-stopped` plus Docker's own systemd unit means the Pi comes
   back on its own after a power cut. Nothing else to configure.

5. Set the capture level while music is casting:

   ```bash
   docker exec -it cast-to-roon amixer -c 1
   ```

   USB cards usually expose a single `Mic`/`Line` capture control. Once you know
   the right values, bake them in with `-e AMIXER_INIT="sset 'Capture' 80% cap"` so
   they survive reboots.

## Point Roon at the Pi

The stream URL becomes `http://<pi-ip>:8000/cast.flac`. Give the Pi a DHCP
reservation in your router first — Roon stores the station as a literal URL, and
a changed IP means editing the station.

Everything else in [roon.md](./roon.md) applies unchanged.

## Verifying the signal

```bash
docker logs cast-to-roon                       # encoder should not be restarting
curl -s http://localhost:8000/status-json.xsl  # /cast.flac should be listed
```

For level measurement, `scripts/find-line-in.sh -m` from this repo works on the
Pi too — it only needs Docker.

## Keeping it updated

Same image and the same `:latest` tag as everywhere else:

```bash
docker pull ghcr.io/lepis0/cast-to-roon:latest
docker rm -f cast-to-roon && docker run -d ...   # same command as above
```

Or install Watchtower on the Pi if you want it automatic.

## Quality note

This path is analog: the LP10 converts to analog, the USB card converts back to
digital. The FLAC stream is lossless from that point on, but the D/A → A/D round
trip has already happened. If you want to avoid it, connect the LP10's **optical
S/PDIF output** to a capture device with an optical input — the signal then stays
digital end to end. Such USB devices are rarer and more expensive than a UCA222,
so start with analog and only chase this if you can hear a problem.
