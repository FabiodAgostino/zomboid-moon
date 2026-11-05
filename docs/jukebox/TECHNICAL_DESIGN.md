# Jukebox (Moon): design tecnico

La mod `JukeboxMoon` («Jukebox (Moon)») fa suonare i jukebox vanilla con i CD di un catalogo che l'admin prepara fuori
dal gioco. Le decisioni sono in `DECISIONI.md`, il confronto con True Moozic in `UPSTREAM_AUDIT.md`. Ogni metodo del
gioco nominato qui è verificato nel jar della 42.21 (`javap`) o nel suo Lua.

## Le parti

| Parte | Dove | Cosa fa |
|---|---|---|
| Motore | `mods/JukeboxMoon/` (questo repo) | Lua, finestre, testi, opzioni. Cambia di rado; arriva con le release del launcher |
| Catalogo | generato da `tools/jukebox` nella cartella dell'admin | Pubblico: oggetti CD, suoni, copertine, `CatalogData.lua`, nomi dei CD. Cifrato: l'audio in pezzi, un pacchetto per album. Mai in git |
| Pubblicazione | `python -m tools.jukebox publish` | Carica il catalogo nella release `jukebox` di GitHub (pre-release, il launcher non la prende per una sua versione) e copia motore e catalogo pubblico nella mod del server, con la chiave |
| Chiave | sul server, `Zomboid/Lua/JukeboxMoon_server_key.txt` | Il server la dà a chi entra (comando `key`); la mod la scrive in `Zomboid/Lua/JukeboxMoon_key.txt` sul PC del giocatore |
| Launcher | `launcher/` (questo repo) | Installa motore e catalogo pubblico a tutti; con la chiave scarica e decifra gli album nuovi o cambiati. Nessun passaggio a mano, niente Discord |

## Il gioco

### Il jukebox

- Riconoscimento: un oggetto la cui sprite ha `CustomName = Jukebox` (le caselle `recreational_01_0` e `_1`), oppure
  un nostro jukebox convertito (contenitore di tipo `jukeboxmoon`).
- Conversione, **solo sul server**, alla prima apertura: `square:transmitRemoveItemFromSquare(vanilla)`, poi
  `IsoThumpable.new(getCell(), square, sprite, false, {})` con `setIsContainer(true)`, contenitore `jukeboxmoon`
  (`setType`, `setCapacity`, `setExplored(true)` perché il gioco non ci metta bottino,
  `setAcceptItemFunction("AcceptItemFunction.JukeboxMoon")`), `setIsDismantable(false)`, `setCanBarricade(false)`,
  `setIsThumpable(false)`, `setBlockAllTheSquare(true)`, `AddSpecialObject(obj, indice)`,
  `transmitCompleteItemToClients()`. L'idea è di True Moozic, il codice è nostro.
- I CD si mettono e si tolgono con la finestra del bottino del gioco: il trasferimento lo valida il server, che chiama
  la nostra funzione di accettazione (solo CD del catalogo, al massimo `MaxCDsPerJukebox`). Niente contenitore finto e
  niente copie: contro i doppioni lavora il gioco.
- Un jukebox con CD dentro non si raccoglie (il gioco rifiuta un contenitore non vuoto,
  `isObjectNoContainerOrEmpty`). Se sparisce in altro modo, la musica si ferma.
- La funzione di accettazione non si salva con l'oggetto: la registriamo dopo `server/Items/AcceptItemFunction.lua`
  (che la svuota) e la rimettiamo sul contenitore a ogni apertura e a ogni controllo del server.

### Lo stato

Decide tutto il server (FR-07, FR-13, FR-14). Il server tiene in memoria i jukebox accesi (`Server.active`, chiave
`x,y,z`): playlist del momento (tracce dei CD nell'ordine del contenitore), indice, traccia, CD, inizio e fine in ms
del suo orologio (`getTimestampMs`), casuale e stato del generatore. A ogni cambiamento manda a tutti
`state {key, x, y, z, on, seq, track, cd, start, ends, reason}` (`sendServerCommand`); a chi entra, alla richiesta
`hello`, la lista intera. Niente scansioni della mappa: i client conoscono i jukebox dal server.

- Avanti, indietro, scelta, casuale: comandi al server, controllati (vivo, stesso piano, entro `USE_TILES` caselle,
  oggetto giusto, CD e traccia presenti nel contenitore, al massimo 8 comandi ogni 4 s a giocatore).
- Fine del brano: la decide il server dalla durata scritta nel catalogo, mai un client.
- Ogni brano parte `LEAD_MS` (1,2 s) dopo il comando o la fine del precedente, perché la notizia arrivi a tutti prima.
- Ogni secondo, per i jukebox accesi con la casella caricata sul server: oggetto ancora lì, corrente, contenuto. Un CD
  tolto con la sua traccia in corso fa passare alla traccia successiva; senza CD, stop («Nessun CD»).
- Corrente: `square:haveElectricity()` o `object:hasGridPower()`, come i suoni d'ambiente del gioco
  (`ObjectAmbientEmitters$AmbientSoundLogic`). Senza, stop («Nessuna alimentazione») e niente ripartenza.
- Casella non caricata sul server (nessuno vicino): il jukebox continua a suonare per conto suo con la playlist che
  conosce; i controlli riprendono quando la casella torna.
- Riavvio: lo stato non si salva (V1), quindi dopo un riavvio i jukebox sono spenti. Restano nell'oggetto (modData
  `jbm`) solo casuale e generatore.
- Casuale deterministico: un generatore Park-Miller (16807, modulo 2^31 - 1) che sta nello stato del server; il
  brano dopo non è mai lo stesso.

### Il suono: pezzi da 10 s

Il Lua del gioco non può far partire un file a metà (`FMODSoundEmitter$FileSound.setTimelinePosition` è vuoto,
`javafmod` non è esposto). Quindi il builder taglia ogni brano in pezzi da `segmentMs` (10 s): il pezzo `k` va da
`k * 10 s` a `(k + 1) * 10 s + overlapMs` (250 ms), con una dissolvenza in uscita negli ultimi 250 ms e una in entrata
nei primi 250 ms del pezzo dopo. Due pezzi vicini si sovrappongono per 250 ms sullo stesso audio: se il pezzo dopo
parte con un fotogramma di ritardo non c'è silenzio.

Ogni pezzo è uno script `sound JukeboxMoon_T<traccia>_S<pezzo>` con
`clip { file = media/sound/jukeboxmoon/t<traccia>/s<pezzo>.ogg, distanceMin, distanceMax }`, `master = Ambient` (il
cursore «Ambiente» del gioco: il volume della musica del gioco resta libero).

Il client (`client/JukeboxMoon/Player.lua`), a ogni tick, per ogni jukebox acceso entro `HEAR_TILES` (40 caselle):
calcola l'ora del server (`getTimestampMs() + offset`), il pezzo del momento e lo fa partire
(`getWorld():getFreeEmitter(x, y, z)`, `playSound`, `set3D`, `setVolume`). Se arriva a metà di un pezzo aspetta il
successivo (al massimo 10 s di silenzio): così chi arriva tardi, chi si riavvicina e chi rientra sente lo stesso
punto degli altri (FR-03, AT-07, AT-08). Fuori dal raggio non suona niente e non decide niente (AT-09). Il volume è
del giocatore (cursore della finestra, salvato solo sul suo PC).

L'orologio: il client chiede `ping {t0}`, il server risponde con il suo `getTimestampMs()`; l'offset è quello del
campione con il viaggio più breve fra gli ultimi otto (cinque all'ingresso, poi uno ogni 5 minuti).

Nessun suono per l'IA: il client suona con un emettitore, non con `WorldSoundManager`, quindi gli zombie non lo
sentono (nessuna nuova meccanica di richiamo, §1.2).

### Noia e stress (FR-05, FR-06, FR-07)

Sul server, a ogni minuto di gioco (`EveryOneMinute`): per ogni giocatore collegato e vivo, se c'è almeno un jukebox
che suona davvero (fra inizio e fine del brano, con corrente) entro `BenefitRadiusTiles` caselle (distanza euclidea,
stesso piano salvo `AllowCrossFloorBenefits`), conta un minuto. Ogni `MoodEvaluationMinutes` minuti applica:
`riduzione = tasso_orario × minuti / 60 × moltiplicatore` con `stats:remove(CharacterStat.BOREDOM, …)` e
`stats:remove(CharacterStat.STRESS, …)`, mai sotto zero, poi `syncPlayerStats(player, maschera)`
(`SyncPlayerStatsPacket.getBitMaskForStat`), che il gioco manda dal server al client come fa l'orto
(`SFarmingSystem`). In MP le statistiche sono del server: un client le manda solo con `CanModifyBodyStats`. Più
jukebox non si sommano. `CharacterTrait.DEAF` × `DeafBenefitMultiplier` (0), `CharacterTrait.HARD_OF_HEARING` ×
`HardOfHearingBenefitMultiplier` (0,5). Nessun tratto della mod.

### Catalogo nel gioco

`shared/JukeboxMoon/CatalogData.lua` (generato) definisce `JukeboxMoonCatalog = { version, segmentMs, overlapMs,
albums = { { key, id, item, title, artist, year, loot, archived, tracks = { { key, id, n, title, artist, ms, segments
} } } } }`. Le lettere accentate sono scritte come byte (`\195\160`): Kahlua altrimenti le rompe. `Catalog.lua` lo
legge la prima volta che serve. Senza catalogo, o con una versione diversa da quella del server (che la manda in
`hello`), il client non suona niente e la finestra dice «Musica non disponibile: aggiorna il launcher» (fail closed).

Gli id numerici (`key`) di album e tracce li assegna il builder e li ricorda in `jukebox.lock.json`, nella cartella
della musica: non cambiano mai, e un album tolto diventa «archiviato» (resta l'oggetto, niente bottino né spawn).

### Bottino e spawn

- `server/JukeboxMoon/Distributions.lua`, `OnPreDistributionMerge`: i CD si aggiungono alle liste del gioco che hanno
  già CD (`CrateCompactDiscs`, `MusicStoreCDs`, `ElectronicStoreMusic`, `BandPracticeInstruments`,
  `MovieRentalShelves`, `LivingRoomShelf*`, `RecRoomShelf`, `BedroomSidetable*`, `BedroomDresser*`), con un peso per
  lista diviso fra gli album secondo `lootWeight`. Mai una lista sostituita.
- Spawn admin: il pulsante «Jukebox» della finestra ZomBOT (`ZomBotMenu`, `extra`); il server ricontrolla il ruolo
  (`getRole():hasAdminPower()` o `CanSetupNonPVPZone`), al massimo 20 CD per volta, solo album non archiviati.

### Opzioni (sandbox, pagina «Jukebox (Moon)»)

`JukeboxMoon.Enabled`, `MaxCDsPerJukebox` (1–100, 20), `ShuffleAllowed`, `EnableCDLoot`, `LootRarity` (1 raro,
2 normale, 3 comune), `MoodEffectsEnabled`, `BenefitRadiusTiles` (1–30, 10), `BoredomReductionPerGameHour` (4),
`StressReductionPerGameHour` (0,02), `MoodEvaluationMinutes` (1–60, 10), `DeafBenefitMultiplier` (0),
`HardOfHearingBenefitMultiplier` (0,5), `AllowCrossFloorBenefits` (no).

## La distribuzione

Scelta dell'utente (5 novembre 2026): automatica e sicura, **niente Discord**. Chi può entrare su Moon ha già un
account e la password del server: è il server del gioco a dare la chiave della musica.

### Il pacchetto del catalogo

`tools/jukebox build` scrive in `dist/<catalogVersion>/`:

- `catalog-<hash>.zip`, **pubblico**: `42/media/scripts/JukeboxMoon_catalog.txt` (oggetti CD), `…_sounds.txt` (uno
  script per pezzo), `42/media/lua/shared/JukeboxMoon/CatalogData.lua`, `42/media/lua/shared/Translate/IT|EN/ItemName.json`,
  `42/media/textures/Item_JukeboxMoon_CD_<n>.png` e le copertine. Con questo un giocatore entra anche senza musica:
  conosce i CD e non sente niente.
- `a<album>-<hash>.jbm`, **cifrato**, uno per album: lo zip dei pezzi `42/media/sound/jukeboxmoon/t<traccia>/s<pezzo>.ogg`,
  cifrato con AES-256-GCM (`JBM1` + nonce di 12 byte + testo cifrato + tag). Il nonce viene dall'HMAC della chiave
  sull'impronta dello zip: lo stesso album dà lo stesso file, due album diversi mai lo stesso nonce. Un album per file
  perché una release di GitHub tiene al massimo mille allegati, e i pezzi sono migliaia.
- `manifest.json`, pubblico: `catalogVersion` (i primi 16 caratteri dello SHA-256 della lista di tutti i file),
  `packageVersion` (versione del motore), `keyId` (i primi 16 caratteri dello SHA-256 della chiave), il catalogo
  pubblico e gli album, ognuno con nome dell'allegato, byte, SHA-256 dell'allegato e, per ogni file dentro, percorso,
  byte e SHA-256.

La stessa sorgente con gli stessi strumenti dà gli stessi file (`-fflags +bitexact`, zip con date fisse, nonce
derivato), e i pezzi già fatti si riusano se brano e parametri non cambiano. Si costruisce in una cartella temporanea
e si rinomina alla fine: un errore non lascia mai un pacchetto a metà.

### La chiave

- 32 byte casuali, scritti dal builder la prima volta in `jukebox.key`, nella cartella della musica dell'admin (fuori
  dal repo). `publish` la copia sul server in `Zomboid/Lua/JukeboxMoon_server_key.txt`.
- Il server la legge all'avvio e la manda nel benvenuto (`key {key, id}`) a ogni giocatore collegato: in MP solo chi
  ha passato l'accesso del server; in single player l'admin che prova.
- La mod del giocatore la scrive in `Zomboid/Lua/JukeboxMoon_key.txt` (solo se è una chiave e se è cambiata); il
  launcher la legge da lì e controlla che sia quella del catalogo (`keyId`). La prima sessione su Moon di un
  giocatore nuovo è senza musica; dalla seconda c'è.
- Una chiave che gira fuori dal gruppo apre la musica a chi la ha: `build --new-key` ne fa una nuova e ricifra tutto.
  L'audio installato sul PC è in chiaro (il gioco deve leggerlo): la cifratura protegge la musica pubblicata, non i
  file di chi gioca.

### GitHub

- Release `jukebox` del repo, **pre-release**: il launcher prende per sue solo le release normali
  (`Sources.cs`: `!Draft && !Prerelease`). Allegati: `manifest.json` (sostituito a ogni pubblicazione, per ultimo),
  `catalog-<hash>.zip` e `a<album>-<hash>.jbm` (per contenuto: un file già caricato non si ricarica). `publish
  --prune` toglie gli allegati che nessuno degli ultimi tre manifest usa.
- Il launcher li scarica da `https://github.com/<repo>/releases/download/jukebox/<nome>`, senza API.

### Il server

`publish` copia, via ssh su cirene, il motore (`mods/JukeboxMoon` del repo) e il catalogo pubblico in
`~/server/zomboid/live/Zomboid/mods/JukeboxMoon` (prima in una cartella accanto, poi lo scambio) e la chiave. Il server
li carica al riavvio. L'audio sul server non serve.

### Launcher

- `mods.json`: la voce `jukebox-moon` installa `mods/JukeboxMoon` in `{zomboid}/mods/JukeboxMoon` con `mirror`, e
  `pack` dice la release del catalogo. I file del catalogo entrano nel piano della mod come quelli del repo: lo stesso
  confronto byte per byte, e il `mirror` non li tocca.
- Il catalogo pubblico è obbligatorio come il motore: GIOCA lo installa prima di avviare il gioco. L'audio no: senza
  chiave la scheda dice «La musica arriva dopo la prima volta su Moon».
- Si scaricano solo gli album che mancano o sono cambiati, si verifica l'impronta dell'allegato, si decifra (la chiave
  sbagliata non passa il tag di GCM) e si verifica ogni file prima di installarlo (`Core/Pack.cs`, launcher 1.0.3).
  Le impronte dei file installati si ricordano per percorso, dimensione e data (`Core/HashCache.cs`): centinaia di MB
  non si rileggono a ogni avvio.
- Per provare un pacchetto prima di pubblicarlo: `MoonLauncher.exe --pacchetto <dist>\<versione>` (con `--sorgente`
  su una copia del repo dove la mod è «installabile»).
