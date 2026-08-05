# Cast-to-Roon Bridge — projektispeksi

## Tavoite

Ottaa vastaan ääntä puhelinsovelluksista (Google Cast / "castaus") ja
muuntaa se FLAC-tasoiseksi Icecast-radioksi, jonka Roon lisää
verkkoradioasemaksi. Tällöin mistä tahansa Cast-tuetusta sovelluksesta voi
soittaa musiikkia, ja Roonin oma multiroom hoitaa toiston useaan huoneeseen
yhtäaikaa.

Sama arkkitehtuuriperiaate kuin `vinyl-streamer`-projektissa: audiolähde →
Icecast-lähde (FLAC) → Roon poimii sen verkkoradiona.

## Suositeltu arkkitehtuuri

> **Korjaus 5.8.2026:** alkuperäinen suunnitelma nojasi Unraid-koneen
> onboard Line In -tuloon. **Se ei toimi**: Unraidin kerneli sisältää vain
> ALSA:n ytimen eikä yhtäkään korttiajuria — ei `snd-hda-intel`ia
> (onboard) eikä `snd-usb-audio`ta (USB-äänikortit). Todennettu kernelillä
> 6.18.38-Unraid, ks. [docs/unraid.md](./docs/unraid.md#unraid-kernel-has-no-sound-drivers).
> Kaappaus on siis tehtävä muulla laitteella; arkkitehtuuri alla on
> päivitetty vastaavasti.

```
[Puhelin/appi: Yle Areena, Spotify, jne.]
              │  (Google Cast / AirPlay 2 / Spotify+Tidal Connect — verkon yli)
              ▼
      Arylic LP10 (~90–100 €)
              │  (fyysinen kaapeli: 3.5mm/RCA tai optinen)
              ▼
   Kaappauslaite: RPi + USB-äänikortti  (tai Linux-VM Unraidilla,
   jolle emolevyn äänipiiri passthroughataan vfio-pci:llä)
              │  (--device /dev/snd passthrough)
              ▼
   Docker-kontti: ffmpeg → Icecast2 (FLAC-enkoodaus)
              │
              ▼
   Roon (lisätty radio-URL:na) → Roonin multiroom → huoneet
```

**Kaappauslaitteelle kaksi vaihtoehtoa:**

1. **RPi + USB-äänikortti LP10:n vierellä** (~40–50 €) — suositus.
   Sama Docker-image (arm64 on buildattu), striimaa Icecastiin verkon yli.
   Ei riipu Unraidin kernelistä, ja LP10 saa olla missä tahansa: vain
   RPi:n ja LP10:n välillä tarvitaan kaapeli, ei Unraid-koneeseen asti.
2. **Linux-VM Unraidilla**, jolle emolevyn HD-audio-laite annetaan
   vfio-pci-passthroughina (0 €, mutta edellyttää että äänipiiri on omassa
   IOMMU-ryhmässään, ja tuo ylläpidettävän VM:n). Kokeilemisen arvoinen jos
   haluaa pitää kaiken yhdellä koneella — tarkista IOMMU-ryhmät ensin
   Unraidin Tools → System Devices -sivulta.

Unraid pyörittää yhä Roonia ja muuta infraa; vain äänen kaappaus siirtyy
pois siltä.

## Kohdesovellukset ja niiden ratkaisu

| Sovellus    | Reitti                                    | Huomio |
|-------------|--------------------------------------------|--------|
| Tidal       | **Ei bridgeä** — Roonin natiivi Tidal-integraatio (Settings → Services) | Parempi laatu (Hi-Res FLAC asti) kuin mikään cast-reitti antaisi |
| Yle Areena  | **Arylic LP10** (Google Cast built-in) | Android-appi tukee vain aitoa Google Castia, ei DLNA:ta/AirPlaytä |
| (bonus)     | LP10 hoitaa myös AirPlay 2, Spotify Connect, Tidal Connect, DLNA samassa laitteessa | Kattaa käytännössä kaikki muutkin cast-sovellukset ilmaiseksi |
| (backup)    | Bluetooth A2DP-sink (jos rakennat RPi-variantin) | Toimii aina, kaikesta puhelimen äänestä — mutta SBC-koodekki on häviöllinen, ei aidosti lossless |

**Huom:** koko perhe käyttää Android-puhelimia, joten AirPlay ei ole
ensisijainen reitti — LP10:n AirPlay-tuki on mukana lähinnä tulevaisuutta
varten (esim. jos joku vieras käyttää iPhonea).

## Miksi ei ohjelmallinen Chromecast-emulointi

Tutkittu ja hylätty vaihtoehto: emuloida softalla laite joka näkyisi
Chromecastina Areena-sovellukselle. Ei toteuteta, koska:
- Google Cast -protokolla vaatii sertifioinnin tuotantosovelluksille
- Avoimen lähdekoodin emulaattorit (esim. NymphCast) ovat vanhentuneita/video-
  fokusoituja, eivät luotettavia äänelle
- BubbleUPnP Server tekee saman asian toisin päin (oikea Chromecast → DLNA),
  ei ratkaise ongelmaa

→ Ratkaisu on käyttää **oikeaa Cast-yhteensopivaa laitetta** (Arylic LP10)
vastaanottimena ja kaapata sen audiolähtö — sama periaate kuin
vinyylistriimerissä, mutta lähde on jo digitaalinen.

## Verkkovaatimukset

- Google Cast (LP10) toimii **mDNS-löytämisellä**, joka vaatii puhelimen ja
  LP10:n olevan samassa verkkosegmentissä (sama SSID/aliverkko) — ei
  eristetyssä vieras-/IoT-verkossa jossa on client isolation päällä
- UniFi Express -mesh on hyvä lähtökohta jos verkkoa ei ole segmentoitu
  VLANeihin — silloin toimii suoraan
- **LAN-kaapeli suositeltavampi kuin WiFi** LP10:lle jos mahdollista —
  luotettavampi mDNS-toiminta kuin mesh-WiFillä roamingin aikana. LP10:ssä
  on sekä WiFi että 10/100 Ethernet-portti
- Jos verkko joskus segmentoidaan VLANeihin, UniFin mDNS-reflaattori-
  asetus mahdollistaa Cast-toiminnan yli VLAN-rajojen
- **Tärkeä erottelu:** castaus (puhelin → LP10) toimii verkon yli
  sijainnista riippumatta, mutta LP10:n audiolähtö capture-laitteeseen on
  aina fyysinen kaapeli — LP10:n täytyy siis olla kaapelin kantomatkan
  päässä kaappauslaitteesta (RPi tai VM-host)

## Rauta

**Ensisijainen (suositeltu) kokoonpano:**
- **Arylic LP10** (~90–100 €) — tukee samassa paketissa Google Cast/
  Chromecast built-in, AirPlay 2, Spotify Connect, Tidal Connect,
  Bluetooth, DLNA/UPnP. Ulostuloina 3.5mm/RCA-linja ja optinen S/PDIF
- **Raspberry Pi** (Zero 2 W ~20 €, tai 3A+/4 jos löytyy laatikosta) +
  **USB-äänikortti** (Behringer UCA222 ~30 €, tai mikä tahansa USB Audio
  Class -laite jossa on line-tulo) LP10:n vierellä
- Kaapeli LP10:n lähdöstä USB-äänikortin tuloon (muutama euro)

**Miksi ei Unraid-koneen omaa Line Iniä (alkuperäinen suunnitelma):**
emolevyssä *on* kunnollinen Line In (ASUS TUF GAMING B550-PLUS, Realtek
ALC S1200A, vaaleansininen portti), mutta Unraidin kernelissä ei ole
`snd-hda-intel`-ajuria — eikä `snd-usb-audio`ta, joten USB-äänikorttikaan
ei pelasta. `/lib/modules/$(uname -r)/kernel/sound/` sisältää vain ALSA:n
ytimen. Tämä koskee koko Unraid-hostia riippumatta siitä mihin porttiin
kaapeli kytketään.

**Varavaihtoehdot:**
- **Linux-VM Unraidilla** + emolevyn äänipiirin vfio-pci-passthrough: ei
  uutta rautaa lainkaan, VM:n oma kerneli tuo ajurit. **Todennettu
  toimivaksi vaihtoehdoksi 5.8.2026:** AMD Starship/Matisse HD Audio
  Controller (1022:1487, 0d:00.4) on omassa IOMMU-ryhmässään 25 ilman
  USB-ohjaimia, joten passthrough on turvallinen. Ohje:
  [docs/unraid-vm.md](./docs/unraid-vm.md). Ehto: LP10 on saatava
  kaapelinmitan päähän palvelimen takapaneelista
- Mikä tahansa muu jo olemassa oleva Linux-kone LP10:n lähellä käy
  kaappauslaitteeksi RPi:n sijaan — image on amd64 + arm64
- **Custom-kerneli** (Unraid Kernel Helper) äänituella: toimii, mutta
  vaatii kernelin uudelleenkäännön jokaisen Unraid-päivityksen yhteydessä
  — ei suositella
- Jos LP10:n ja kaappauslaitteen välinen etäisyys on kohtuuton: erillinen
  RPi Zero 2 W (~20 €) + USB-äänikortti LP10:n vierellä, striimaa
  Icecastiin verkon yli
- Pidempi kaapelimatka: **optinen Toslink** (n. 10–15 €, 5–10 m) ei
  degradoidu samalla tavalla kuin pitkä analogikaapeli — edellyttää
  SPDIF-in-liitäntää (harvinaisempi emolevyillä, yleisempi RPi:n USB-
  äänikorteissa)

**Muut Cast-laitevaihtoehdot vertailun vuoksi:**
- **WiiM Pro/Pro Plus** (~150–220 €) — tukee myös Chromecastia, parempi
  DAC mutta kalliimpi. **WiiM Mini ei tue Chromecastia** — yleinen
  sekaannus, ei sovi tähän
- **Budjettivaihtoehto:** käytetty Chromecast Audio (n. 20–30 €,
  Tori/eBay, tuotanto lopetettu mutta paljon tarjolla) — halvempi mutta
  epävarmempi saatavuus
- **Jos jo omistat tavallisen (video-)Chromecastin:** HDMI-audioekstraktori
  (n. 10–20 €) purkaa äänen HDMI-signaalista. Riski: toimivuus riippuu
  ekstraktorin EDID-raportoinnista, hit-or-miss halvimmilla malleilla —
  tee ensiasennus oikealla näytöllä kiinni, osta palautettavalta
  myyjältä. Chromecast Audio/LP10 on luotettavampi koska ei
  EDID/HDCP-kikkailua

**Arvioitu kokonaishinta:** n. **140–160 €** suositellulla kokoonpanolla
(LP10 + RPi + USB-äänikortti + kaapelit), tai n. **90–110 €** jos
VM-passthrough toimii eikä RPi:tä tarvita. Alkuperäinen 90–110 €:n arvio
oletti Unraidin onboard-tulon toimivan.

## Ohjelmistokomponentit

1. **Icecast2** — striimauspalvelin, FLAC-tuki
2. **ffmpeg** — kaappaa ALSA-lähteen ja lähettää Icecastiin FLAC-muodossa
   (valittu darkicen/liquidsoapin sijaan, ks. "Toteutuksen tila")
3. Docker-passthrough: `--device /dev/snd` konttiin — yleinen ja hyvin
   dokumentoitu kuvio (vrt. Snapcast-tyyppiset audio-kontit). Vaatii että
   *hostin* kernelissä on äänikorttiajurit, mikä sulkee Unraidin pois
4. **RPi-varianttia varten:** `snd-aloop`/`dmix` mikserinä LP10-tulon ja
   Bluetooth-backupin yhdistämiseen, sekä **BlueZ + bluez-alsa (bluealsa)**
   Bluetooth A2DP-sinkiksi (kaappaa kaiken puhelimen äänen, mutta SBC-
   koodekki on häviöllinen — ei aidosti lossless, vain varareitti)
5. Budjettireitin tapauksessa (ei LP10:tä) tarvitaan lisäksi:
   - `shairport-sync` (AirPlay 2)
   - `librespot` / `go-librespot` (Spotify Connect)
   - `gmrender-resurrect` tai `upmpdcli` (DLNA/UPnP-toistin)

## Rajoitukset / tiedossa olevat kompromissit

- **Viive:** Icecast tuo muutaman sekunnin puskurointiviiveen — ei haittaa
  taustamusiikissa
- **Yksi istunto kerrallaan** LP10:ssä — ei ongelma, koska Roon hoitaa
  moninkertaisen jakelun eteenpäin huoneisiin
- LP10-reitti kattaa käytännössä *kaikki* Chromecast-yhteensopivat
  sovellukset, ei vain Areenan — hyvä bonus
- **Bluetooth-backup (jos käytössä) ei ole lossless**: SBC-koodekki on
  häviöllinen (max n. 328 kbit/s), FLAC-enkoodaus jälkikäteen ei palauta
  hävinnyttä laatua. Kaappaa myös kaiken muun puhelimen äänen (ilmoitukset,
  puhelut) — käytä vain varareittinä

## Toteutusjärjestys (ehdotus)

1. ✅ Icecast2 + FLAC-striimaus pystyyn Docker-kontissa Unraidilla, testaa
   yhdellä staattisella audiotiedostolla että Roon löytää ja soittaa aseman
   (tehty `SOURCE_MODE=tone`-testiäänellä, Roon soittaa)
2. Hanki Arylic LP10 **ja kaappauslaite** (RPi + USB-äänikortti, tai
   pystytä VM), kytke LP10:n analogilähtö sen tuloon, varmista että
   signaali kaappautuu (`arecord`-testi kontista)
3. ✅ Yhdistä kaappaus Icecast-lähteeseen (`SOURCE_MODE=alsa`) — koodi valmis,
   jäljellä vain oikean `ALSA_DEVICE`:n varmistaminen raudan saavuttua
4. Testaa Yle Areenalla Androidista päästä päähän (Cast-painike → LP10)
5. Lisää Roonissa asema huoneryhmiin ja testaa monihuonetoisto
6. (Valinnainen) jos etäisyys vaatii RPi-varianttia, toteuta se samalla
   periaatteella + Bluetooth A2DP-backup — image on jo multi-arch (arm64)

## Toteutuksen tila

Ohjelmistopuoli on valmis ja julkaistu: <https://github.com/lepis0/cast-to-roon>,
image `ghcr.io/lepis0/cast-to-roon:latest`.

Enkooderiksi valikoitui **ffmpeg** darkicen/liquidsoapin sijaan — sama ratkaisu
kuin vinyylistriimerissä: yksi prosessi tuottaa sekä FLAC/Ogg- että
MP3-varamountin, eikä erillistä konfiguraatiokieltä tarvita.

Ennen raudan saapumista koko Roon-pää voi testata ilman LP10:tä:
`SOURCE_MODE=tone` (440 Hz testiääni) tai `SOURCE_MODE=file` (looppaa
`/config/test.flac`). Tämä on tehty ja Roon soittaa aseman.

**Avoin asia:** kaappauslaite. Unraid-host ei kelpaa (ei äänikorttiajureita
kernelissä), joten valinta on VM-passthrough (0 €, IOMMU-ryhmä todettu
siistiksi) tai RPi + USB-äänikortti (~50 €, LP10 saa olla missä tahansa).
Kontti itsessään ei muutu kummassakaan tapauksessa — vain `ALSA_DEVICE`
ja se, millä koneella kontti pyörii. Ratkaisee käytännössä se, mihin LP10
halutaan sijoittaa.

Yksityiskohdat: [README.md](./README.md),
[docs/unraid-vm.md](./docs/unraid-vm.md),
[docs/raspberry-pi.md](./docs/raspberry-pi.md),
[docs/unraid.md](./docs/unraid.md), [docs/roon.md](./docs/roon.md).
