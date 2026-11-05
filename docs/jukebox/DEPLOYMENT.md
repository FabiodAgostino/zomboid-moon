# Jukebox (Moon): installazione e aggiornamenti

Niente di questo è stato fatto: ogni passo sul server, su GitHub e nel launcher aspetta il sì dell'utente.

## La prima volta

1. **Prova in single player** (`README_ADMIN.md`, passo 4) con la musica demo o con la tua.
2. **Release del launcher 1.0.3** con il motore della mod, ancora `"state": "disattivata"` in `mods.json`: i
   launcher si aggiornano, nessuno installa ancora il jukebox. Come per ogni release: `launcher/README.md`,
   «Pubblicare una release».
3. **Costruisci e pubblica il catalogo** (`README_ADMIN.md`, passi 3 e 5). `publish` crea la pre-release `jukebox` su
   GitHub e copia motore, elenco dei CD e chiave sul server.
4. **Server**, a server vuoto (`zomboid-ctl status`), su cirene:
   - backup del salvataggio e della configurazione (`Saves/Multiplayer/amici`, `Server/amici.ini`,
     `Server/amici_SandboxVars.lua`);
   - in `amici.ini` aggiungi la mod a `Mods=` (`Mods=ZomBOTMoon;JukeboxMoon`). **Niente in `WorkshopItems`**;
   - le opzioni, se vuoi cambiarle, in `amici_SandboxVars.lua`, sezione `JukeboxMoon` (sotto); senza, valgono quelle
     della specifica;
   - riavvia il server.
5. **Accendi la mod nel launcher**, solo quando tutti hanno il launcher 1.0.3: in `mods.json` sul ramo `main`,
   `"state": "installabile"` (togli `stateNote`). Basta il commit: i launcher lo leggono all'avvio. Da quel momento
   GIOCA la installa a tutti, perché è `required`: chi non ce l'ha riceverebbe dal server CD che il suo gioco non
   conosce. **Un launcher 1.0.2 non conosce `pack`**: installerebbe solo il motore, senza l'elenco dei CD, e il server
   non lo farebbe entrare (controllo dei file). Il launcher vecchio propone l'aggiornamento ma non lo impone: avvisa
   i giocatori di aggiornarlo prima di questo passo. Dopo l'aggiornamento si sistema da solo.
6. **ZomBOT annuncia l'uscita del jukebox**, nello stesso momento: nel repo zomboid-discord la nuova `Release` in cima a
   `RELEASES` (`src/zombot/releases.py`) **deve avere la riga del CD unico** («Love storii...»: uno solo in tutta la
   storia del server, sui corridori, molto raro). Il testo lo tiene ZomBOT (`zombot.jukebox.ANNOUNCEMENT`). Il bot
   legge anche `Zomboid/Lua/jukeboxmoon_unique.json`, scritto da questa mod, e annuncia in #zombot chi trova il CD:
   deve essere in produzione prima che il server parta con la mod, o un ritrovamento dei primi minuti arriverebbe in
   ritardo (lo annuncia comunque, una volta).

Chi usa `mod-moon-server.bat`, un Mac o Linux non ha il launcher: deve copiare a mano `mods/JukeboxMoon` del repo e
il catalogo pubblico (lo zip `catalog-*.zip` della pre-release `jukebox`, scompattato nella stessa cartella). Senza
launcher la musica non arriva.

## Le opzioni del server

In `amici_SandboxVars.lua`, dentro `SandboxVars`:

```lua
JukeboxMoon = {
    Enabled = true,
    MaxCDsPerJukebox = 20,
    ShuffleAllowed = true,
    EnableCDLoot = true,
    LootRarity = 1,                       -- 1 rari, 2 normali, 3 comuni
    MoodEffectsEnabled = true,
    BenefitRadiusTiles = 10,
    BoredomReductionPerGameHour = 4.0,    -- su 100
    StressReductionPerGameHour = 0.02,    -- su 1
    MoodEvaluationMinutes = 10,
    DeafBenefitMultiplier = 0.0,
    HardOfHearingBenefitMultiplier = 0.5,
    AllowCrossFloorBenefits = false,
},
```

Il bottino si decide all'avvio del server: `EnableCDLoot` e `LootRarity` contano dal riavvio dopo, e solo per i
contenitori non ancora aperti.

## Un catalogo nuovo (album aggiunti, tolti, rifatti)

`build`, `publish`, riavvio del server a server vuoto. I giocatori aprono il launcher, che scarica solo gli album
cambiati. Gli id non cambiano mai: i CD nei salvataggi restano validi.

## Un motore nuovo (il codice della mod)

Alza `modversion` in `mods/JukeboxMoon/42/mod.info`, pubblica una release del launcher, poi `publish` (che ricopia il
motore sul server) e riavvio. Il catalogo dice per quale motore è stato fatto (`packageVersion`).

## Tornare indietro

- **Catalogo**: `publish` di una versione vecchia di `dist`, riavvio. Se il catalogo vecchio non ha un album che è
  già nei salvataggi, quei CD diventano sconosciuti: torna indietro solo a cataloghi che li hanno.
- **Motore**: la versione precedente si sceglie nel launcher; sul server, `Zomboid/JukeboxMoon-publish/old` è la
  copia di prima dell'ultimo `publish` (fuori da `mods`: due cartelle con lo stesso id in `mods` e il gioco potrebbe
  caricare quella sbagliata).
- **Togliere la mod**: togli `JukeboxMoon` da `Mods=`, riavvia, rimetti `"state": "disattivata"`. I jukebox
  convertiti restano jukebox con un contenitore: i CD dentro diventano oggetti sconosciuti.

## Cosa c'è dove

| Dove | Cosa |
|---|---|
| Repo, `mods/JukeboxMoon` | Il motore |
| Repo, `tools/jukebox` | Il builder |
| PC dell'admin, cartella della musica | Brani, `album.json`, `jukebox.lock.json`, `jukebox.key` (e `jukebox.key.<id>`, le chiavi di prima), la cache dei pezzi |
| PC dell'admin, `dist/<versione>` | I pacchetti costruiti |
| GitHub, pre-release `jukebox` | `manifest.json`, `manifest-<versione>.json`, `catalog-*.zip`, `a*-*.jbm` (cifrati) |
| cirene, `~/server/zomboid/live/Zomboid/mods/JukeboxMoon` | Motore + elenco dei CD, senza audio |
| cirene, `~/server/zomboid/live/Zomboid/JukeboxMoon-publish/old` | La copia di prima dell'ultimo `publish` |
| cirene, `~/server/zomboid/live/Zomboid/Lua/jukeboxmoon_unique.json` | I CD unici: trovati o no, e da chi (per ZomBOT) |
| cirene, `~/server/zomboid/live/Zomboid/Lua/JukeboxMoon_server_key.txt` | La chiave (solo il proprietario la legge) |
| PC di un giocatore, `%UserProfile%\Zomboid\mods\JukeboxMoon` | Motore, elenco dei CD e audio, dal launcher |
| PC di un giocatore, `%UserProfile%\Zomboid\Lua\JukeboxMoon_key.txt` | La chiave, scritta dal gioco |
