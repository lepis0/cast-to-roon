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

Realtek codecs boot muted *and* listening to the microphone input. While music
is playing into the jack:

```bash
docker exec -it cast-to-roon amixer -c 0 sset 'Input Source',0 Line
docker exec -it cast-to-roon amixer -c 0 sset 'Input Source',1 Line
docker exec -it cast-to-roon amixer -c 0 sset 'Capture',0 60% cap
docker exec -it cast-to-roon amixer -c 0 sset 'Capture',1 60% cap

docker exec cast-to-roon ffmpeg -hide_banner -nostdin \
  -i http://127.0.0.1:8000/cast.flac -t 5 -af volumedetect -f null - 2>&1 \
  | grep max_volume
```

The measurement goes through the stream because the container already holds the
capture device open — `scripts/find-line-in.sh` cannot open it a second time
while the encoder is running. See
[unraid.md](./unraid.md#3-set-capture-levels) for what these controls do and why
the one called `Line` is not among them.

Once the levels work, make them permanent with
`-e AMIXER_INIT="sset 'Input Source' Line;sset 'Capture' 60% cap"` — the container
re-applies them on every start, which matters because ALSA mixer state does not
survive a reboot.

## 6. Autostart

Set the VM to autostart in the VMs tab. Docker's own service starts the
container from `--restart unless-stopped`, so a power cut recovers on its own:
host → VM → container → stream.

## 7. Keep it updated without touching it

The VM does not show up in Unraid's Docker tab, so nothing about it updates
itself unless you set that up. Two mechanisms, one for the container and one for
the OS.

**The container** — a Compose file plus one cron line. Not Watchtower: the
original `containrrr/watchtower` speaks Docker API 1.25, current daemons require
at least 1.40, and it crash-loops on `client version 1.25 is too old`. The
project has not shipped a release since 2024. Community forks exist, but for a
single container this needs no third-party tool at all — and it avoids handing
`/var/run/docker.sock`, which is root on the host, to a container.

Move the settings into a file, so the run command stops living in your shell
history — and so the passwords carry over without being retyped:

```bash
mkdir -p ~/cast-to-roon-stack && cd ~/cast-to-roon-stack

docker inspect cast-to-roon --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E '^(STATION_NAME|ICECAST_SOURCE_PASSWORD|ICECAST_ADMIN_PASSWORD|TZ|SOURCE_MODE|ALSA_DEVICE|AMIXER_INIT)=' \
  > stack.env
chmod 600 stack.env

cat > docker-compose.yml <<'YAML'
services:
  cast-to-roon:
    image: ghcr.io/lepis0/cast-to-roon:latest
    container_name: cast-to-roon
    restart: unless-stopped
    ports:
      - "8000:8000"
    devices:
      - /dev/snd:/dev/snd
    volumes:
      - /opt/cast-to-roon:/config
    env_file:
      - stack.env
YAML

docker rm -f cast-to-roon
docker compose up -d
```

`env_file` takes values literally to end of line, which is what keeps
`AMIXER_INIT`'s quotes and semicolons intact.

Then the nightly update, as a **user** crontab — no root needed, since the
account is already in the `docker` group:

```bash
printf '%s\n' "0 4 * * * cd ~/cast-to-roon-stack && { date; /usr/bin/docker compose pull -q && /usr/bin/docker compose up -d && /usr/bin/docker image prune -f; } >> ~/cast-to-roon-stack/update.log 2>&1" | crontab -
crontab -l
```

`compose up -d` is a no-op when the pulled image is unchanged, so the stream is
only interrupted on the nights a new release actually lands. `image prune`
keeps the superseded layers from filling a 10 GB disk, and `update.log` is there
when you want to know what happened.

**The OS** — Debian's own unattended-upgrades, security updates only:

```bash
sudo apt install -y unattended-upgrades

sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-local >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "07:30";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF

sudo systemctl enable --now unattended-upgrades
```

Kernel updates only take effect after a reboot, and an appliance that nobody
logs into will otherwise run an outdated kernel indefinitely — hence the
automatic one. The time has to fall *after* Debian's upgrade window, not before
it: `apt-daily-upgrade.timer` fires at 06:00 with up to an hour of randomized
delay, and `Automatic-Reboot-Time` schedules the reboot for the next occurrence
of that clock time. Set it to 05:00 and a kernel installed at 06:50 waits until
the following morning; 07:30 reboots the same day. `WithUsers "false"` keeps it
from rebooting out from under an SSH session, and the container returns on its
own through `restart: unless-stopped`.

Check both:

```bash
systemctl list-timers 'apt-daily*'
sudo unattended-upgrade --dry-run --debug | tail -20
docker logs watchtower | tail
```

## Passwordless SSH

Optional, but the alternative is typing a password every time you check on it:

```bash
# on your workstation
ssh-keygen -t ed25519          # skip if you already have a key
ssh-copy-id jani@<vm-ip>       # asks for the password once
ssh -o BatchMode=yes jani@<vm-ip> true && echo ok
```

Once keys work you can turn password logins off entirely. Unraid's VNC console
is the way back in if you ever lose the key, so this is not the one-way door it
would be on a remote server:

```bash
echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/99-no-password.conf
sudo systemctl restart ssh
```

## Maintenance notes

- **Unraid updates** keep the vfio binding (it lives in `/boot/config`), but a
  major version bump is worth a check afterwards.
- **The Roon URL** is the VM's IP, not the Unraid IP: `http://<vm-ip>:8000/cast.flac`.
- **The Unraid container template** in this repo is only useful for `tone`-mode
  testing on the host from here on; the real capture lives in the VM.
