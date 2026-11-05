# Jukebox (Moon): licenze e fonti

| Cosa | Di chi | Note |
|---|---|---|
| Codice della mod (`mods/JukeboxMoon`), del builder (`tools/jukebox`), delle prove (`tests/jukebox`) e del launcher | Moon | Scritto da zero il 5 novembre 2026 |
| `client/ZomBotMenu.lua` | Moon | La copia byte per byte di ZomBOT (Moon) |
| Poster, icona, icone dei CD e copertine disegnate | Moon | Fatti con forme e numeri (`tools/jukebox/art.py`, `generate.py`) |
| Musica demo | nessuno: libera | Fatta con dei numeri da `tools/jukebox/demo.py`, nessuna registrazione |
| Modello del CD nel mondo (`WorldStaticModel = Disk`) | The Indie Stone | Il modello del gioco, solo nominato: nessun file copiato |
| Audio dei CD del gioco (`import-radiovoices`) | Espaidi, Radio Voices (Workshop 3828360540); voci ElevenLabs, canzoni Suno e alcune canzoni vere dei loro autori | Il permesso lo chiede l'admin (decisione dell'utente). Mai in git; su GitHub solo cifrato |
| La musica dei cataloghi | i suoi autori | Responsabilità di chi la pubblica. Il repo non contiene brani; GitHub solo l'audio cifrato |

## True Moozic B42+

[True Moozic B42+](https://steamcommunity.com/sharedfiles/filedetails/?id=3632610172) (a_cow_says, hasteL, talismon,
seguito di True Music di iBrRus) è stata **letta e non copiata**: `docs/jukebox/UPSTREAM_AUDIT.md`. Non ha una licenza né
un permesso di ridistribuzione, e contiene brani commerciali. Da lei viene solo un'idea, riscritta: convertire sul
server il jukebox del gioco in un oggetto con un contenitore. Nessun suo file, testo, suono o immagine è nel progetto.

## Strumenti

- **FFmpeg** (build di gyan.dev, LGPL/GPL) e **ffprobe**: usati sul PC dell'admin per convertire e tagliare l'audio.
  Non sono ridistribuiti.
- **Pillow**, **numpy**, **cryptography** (licenze BSD/MIT/Apache): librerie Python del builder, non ridistribuite.
- **AES-GCM** del launcher: `System.Security.Cryptography.AesGcm` di .NET.
