# Adding the stream to Roon

## Add the station

1. In Roon: **Browse → Live Radio → Add Station**
2. Stream URL: `http://<host-ip>:8000/cast.flac`
   Use the IP, not a `.local` name — Roon Core resolves station URLs itself and
   mDNS is not always available to it.
3. Name: whatever you want to see in the zone (e.g. "Cast").
4. Leave everything else at the defaults and save.

Roon plays Ogg FLAC internet radio natively, so `/cast.flac` is the mount to
use. `/cast.mp3` exists as a fallback for players that cannot handle Ogg FLAC —
you should not need it with Roon.

## Multiroom

Once the station plays in one zone, group the zones as usual (zone picker →
**Group Zones**) and Roon distributes the single Icecast stream to all of them,
in sync. This is why the container only needs to serve one listener: Roon Core
is the only client, and it fans out from there.

## What you should expect

- **Latency.** Icecast buffers, Roon buffers, and the zones re-sync — expect a
  few seconds between hitting play on the phone and hearing it. Fine for
  background listening, not for watching video.
- **Silence, not stops.** When nothing is casting, the receiver's line-out is
  silent but the stream keeps running. Roon stays connected and playing, so the
  next cast starts within the buffer delay instead of needing a restart.
- **Bit depth.** The stream is whatever the capture is, 16-bit/48 kHz by
  default. Roon shows it as a FLAC stream in the signal path.

## Restarting the station

If Roon ever drops the station (Core restart, network blip), just press play
again — the mount is always there as long as the container is healthy. If Roon
reports the station as unavailable, check the container first:

```bash
curl -s http://<host-ip>:8000/status-json.xsl | grep cast.flac
```

No match means the encoder is not connected; see
[troubleshooting.md](./troubleshooting.md).

## Tidal

Do not route Tidal through this. Roon has native Tidal integration
(Settings → Services), which gives you up to Hi-Res FLAC — better than anything
an analog capture chain can deliver.
