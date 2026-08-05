# Capturing on Unraid through a VM

Unraid's kernel has no sound card drivers
([why](./unraid.md#unraid-kernel-has-no-sound-drivers)), but that only stops the
*host* from using the sound card. Handing the whole HD Audio controller to a
small Linux VM via vfio-pci sidesteps the problem entirely: the guest kernel has
the drivers, and this container runs inside the guest.

No new hardware, at the cost of one more VM to keep alive. If the Cast receiver
cannot sit within cable reach of the server, use
[a Raspberry Pi](./raspberry-pi.md) instead — no amount of passthrough moves the
Line In jack off the back of the machine.

## Prerequisite: a clean IOMMU group

Passthrough takes an entire IOMMU group or nothing. List the audio devices with
their groups:

```bash
for f in /sys/kernel/iommu_groups/*/devices/*; do
  grp=$(echo "$f" | cut -d/ -f5); dev=$(basename "$f")
  case "$(lspci -nns "$dev" 2>/dev/null)" in
    *[Aa]udio*) echo "group $grp: $(lspci -nns "$dev")";;
  esac
done
```

You are looking for the motherboard's controller — on AM4 that is
`Starship/Matisse HD Audio Controller [1022:1487]`. An Intel audio device on an
AMD board is the GPU's HDMI/DisplayPort audio function: output only, useless for
capture.

Then check what else shares its group (25 in this example):

```bash
for d in /sys/kernel/iommu_groups/25/devices/*; do lspci -nns "$(basename "$d")"; done
```

**Stop here if a USB controller is in the group.** On AM4 the audio function sits
next to the `Starship/Matisse USB 3.0` controllers, and Unraid boots from — and
keeps running from — a USB flash drive. Passing through the controller holding
that drive means the server does not come back up. Unraid's *PCIe ACS Override*
can split groups artificially, but it defeats the hardware's isolation guarantee
and is a known source of intermittent instability. Not worth it here; get a Pi.

## 1. Bind the device to vfio-pci

**Tools → System Devices** → tick the HD Audio controller → **Bind selected to
VFIO at boot** → reboot.

The host loses nothing, since it had no driver for it in the first place.

## 2. Create the VM

**VMs → Add VM → Debian** (or Ubuntu Server — any distro with a normal kernel).

| Setting        | Value                                            |
| -------------- | ------------------------------------------------ |
| Machine        | Q35                                              |
| BIOS           | OVMF                                             |
| vCPUs          | 1 (2 if you want headroom)                       |
| Memory         | 1024 MB                                          |
| vDisk          | 10 GB                                            |
| Network        | br0, so the VM gets its own LAN IP               |
| **Sound Card** | **the HD Audio controller** — see below          |

The audio device is selected in the **Sound Card** dropdown, *not* under Other
PCI Devices. Unraid filters VGA- and audio-class devices out of that list
because they have dropdowns of their own, so Other PCI Devices looks empty even
though the binding worked. Despite its name, the Sound Card dropdown is a
passthrough selector, not an emulated-audio setting.

If the dropdown is empty too, add the device by hand: switch the VM editor to
**XML View** (toggle at the top right) and put a `hostdev` inside `<devices>`,
with `bus`/`slot`/`function` matching the PCI address from `lspci`:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x0d' slot='0x00' function='0x4'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
</hostdev>
```

The guest-side `<address>` has to point at a free `pcie-root-port`. Unraid's
template creates five of them and the default devices occupy buses `0x01`–`0x04`,
so `0x05` is normally free.

Encoding one stereo FLAC stream is a few percent of a core; this VM is idle
almost all the time.

Install the OS as usual, then give the VM a **DHCP reservation** in your router.
Roon stores the station as a literal URL, so a changed IP means editing the
station by hand.

## 3. Verify the guest sees the card

Inside the VM:

```bash
cat /proc/asound/cards      # should list HD-Audio Generic
arecord -l                  # should list a capture device
```

If `/proc/asound/cards` is empty here, the passthrough did not take — check that
the device shows as bound to vfio-pci in Tools → System Devices, and that the VM
template actually has it ticked.

## 4. Run the container

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"      # log out and back in

docker run -d \
  --name cast-to-roon \
  --restart unless-stopped \
  -p 8000:8000 \
  --device /dev/snd \
  -v /opt/cast-to-roon:/config \
  -e SOURCE_MODE=alsa \
  -e ALSA_DEVICE=hw:0,0 \
  -e ICECAST_SOURCE_PASSWORD=secret1 \
  -e ICECAST_ADMIN_PASSWORD=secret2 \
  -e TZ=Europe/Helsinki \
  ghcr.io/lepis0/cast-to-roon:latest
```

Confirm the device number with `arecord -l` rather than trusting `hw:0,0` — the
passed-through card is usually the only one, but check.

## 5. Wire it up and set levels

Cable from the Cast receiver's line-out to the **light blue Line In** on the
server's rear panel. Not the pink Mic In: it is mono on most codecs and applies
20 dB of boost.

Realtek codecs boot with the capture switch muted. While music is casting:

```bash
docker exec -it cast-to-roon amixer -c 0
./scripts/find-line-in.sh -m          # measures the actual signal level
```

Once you know the working control names, make them permanent with
`-e AMIXER_INIT="sset 'Line' 80% unmute;sset 'Capture' 60% cap"` — the container
re-applies them on every start, which matters because ALSA mixer state does not
survive a reboot.

## 6. Autostart

Set the VM to autostart in the VMs tab. Docker's own service starts the
container from `--restart unless-stopped`, so a power cut recovers on its own:
host → VM → container → stream.

## Maintenance notes

- **Unraid updates** keep the vfio binding (it lives in `/boot/config`), but a
  major version bump is worth a check afterwards.
- **The Roon URL** is the VM's IP, not the Unraid IP: `http://<vm-ip>:8000/cast.flac`.
- **Two hosts to update now**: the container inside the VM does not appear in
  Unraid's Docker tab. Either `docker pull` in the VM or install Watchtower
  there.
- **The Unraid container template** in this repo is only useful for `tone`-mode
  testing on the host from here on; the real capture lives in the VM.
