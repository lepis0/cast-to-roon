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

```
[Puhelin/appi: Yle Areena, Spotify, jne.]
              │  (Google Cast / AirPlay 2 / Spotify+Tidal Connect — verkon yli)
              ▼
      Arylic LP10 (~90–100 €)
              │  (fyysinen kaapeli: 3.5mm/RCA tai optinen)
              ▼
   Unraid-koneen emolevyn Line In
   (ASUS TUF GAMING B550-PLUS, Realtek ALC S1200A,
    vahvistetusti oikea Line In -portti, ei Mic-in)
              │  (--device /dev/snd passthrough)
              ▼
   Docker-kontti: darkice/liquidsoap → Icecast2 (FLAC-enkoodaus)
              │
              ▼
   Roon (lisätty radio-URL:na) → Roonin multiroom → huoneet
```

**Ei tarvita erillistä Raspberry Pi:tä eikä lisäkortteja** — pelkkä LP10 ja
kaapeli riittävät, jos LP10 saadaan sijoitettua kaapelin kantomatkalle
Unraid-koneesta. Hyödyntää olemassa olevaa Docker/Watchtower-infraa.

**Jos etäisyys Unraid-koneeseen on kohtuuton** (esim. eri huone/kerros eikä
kaapelia saa vedettyä järkevästi), varavaihtoehtona pieni erillinen laite
(RPi Zero 2 W, ~20 €) LP10:n vierellä, joka striimaa Icecastiin verkon yli
— tällöin RPi:llä pyörii sama darkice/liquidsoap → Icecast, mutta LP10 saa
olla missä tahansa RPi:n vieressä.

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
  päässä siitä missä ääni napataan talteen (Unraid-kone tai RPi)

## Rauta

**Ensisijainen (suositeltu) kokoonpano:**
- **Arylic LP10** (~90–100 €) — tukee samassa paketissa Google Cast/
  Chromecast built-in, AirPlay 2, Spotify Connect, Tidal Connect,
  Bluetooth, DLNA/UPnP. Ulostuloina 3.5mm/RCA-linja ja optinen S/PDIF
- Kaapeli LP10:n lähdöstä Unraid-koneen Line In -jackiin (muutama euro)
- **Ei muuta** — ASUS TUF GAMING B550-PLUS -emolevyn Realtek ALC S1200A
  -äänipiirissä on vahvistetusti oikea Line In -portti (vaaleansininen,
  ei Mic-in), täysin vakiotuettu `snd-hda-intel`-ajurilla Linuxissa

**Varavaihtoehdot:**
- Jos onboard-Line In ei syystä toimisi: USB-äänikortti (esim. Behringer
  UCA222) Unraid-koneen USB-porttiin — ei PCIe-korttia, koska geneerinen
  USB Audio Class -ajuri on ajuririskitön, kun taas PCIe-äänikortit
  vaativat oman kernel-tuen (vrt. aiempi ajuriharmi Arc B580:n kanssa)
- Jos LP10:n ja Unraid-koneen välinen etäisyys on kohtuuton: erillinen
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

**Arvioitu kokonaishinta:** n. **90–110 €** suositellulla kokoonpanolla
(LP10 + kaapeli, ei muuta rautaa), tai n. **50–80 €** budjettireitillä
(käytetty Chromecast Audio + RPi).

## Ohjelmistokomponentit

1. **Icecast2** — striimauspalvelin, FLAC-tuki
2. **darkice** tai **liquidsoap** — kaappaa ALSA-lähteen (Unraid-kone tai
   RPi) ja lähettää Icecastiin FLAC-muodossa
3. Docker-passthrough Unraidilla: `--device /dev/snd` konttiin — yleinen
   ja hyvin dokumentoitu kuvio (vrt. Snapcast-tyyppiset audio-kontit)
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

1. Icecast2 + FLAC-striimaus pystyyn Docker-kontissa Unraidilla, testaa
   yhdellä staattisella audiotiedostolla että Roon löytää ja soittaa aseman
2. Hanki Arylic LP10, kytke sen analogilähtö Unraid-koneen Line In
   -jackiin, varmista signaali kaappautuu (`arecord`-testi kontista)
3. Yhdistä kaappaus Icecast-lähteeseen (darkice/liquidsoap-konfiguraatio)
4. Testaa Yle Areenalla Androidista päästä päähän (Cast-painike → LP10)
5. Lisää Roonissa asema huoneryhmiin ja testaa monihuonetoisto
6. (Valinnainen) jos etäisyys vaatii RPi-varianttia, toteuta se samalla
   periaatteella + Bluetooth A2DP-backup
