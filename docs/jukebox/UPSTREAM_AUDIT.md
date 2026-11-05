# Audit di True Moozic B42+ (§2.1 della specifica)

Specifica: «Analisi funzionale — Server Jukebox (Project Zomboid Build 42)», v1.0 del 5 novembre 2026.
Audit del 5 novembre 2026.

**Decisione dell'utente (5 novembre 2026): il codice del jukebox lo scriviamo noi.** True Moozic si legge soltanto,
per capire come ha risolto jukebox, sincronia e umore. Nel pacchetto non entra niente di suo: né codice, né suoni, né
texture, né testi. Per questo le classificazioni qui sotto dicono quali idee riprendere e quali lasciare. Non dicono
quali file tagliare da una fork.

## 1. Versioni

| Cosa | Valore |
|---|---|
| Project Zomboid (server e client) | 42.21. Verificato su `projectzomboid.jar` dell'installazione Steam del PC, identica al server (SHA-256 `e1a69eb743ede60b213a0fe7f8b83d4fcab773036d256cc4543a336f3b058a33`) |
| True Moozic | Workshop `3632610172`, «True Moozic B42+ The Music System for Project Zomboid (SP/MP)», manifest Steam `8014246173561012008`, aggiornata il 9 ottobre 2026 (changelog: «MP Lua Reset Hotfix»), 84.412.661 byte, 829 file |
| Impronta dei file | SHA-256 della lista ordinata `sha256sum` di tutti i file: `326c08d83c255b1be800ebfd314935dfc818fa445c2b1a0d093d75ec12f42a4` |
| Come è arrivata | steamcmd di Valve (firmato «Valve»), login anonimo, il 5 novembre 2026. Copia in `originale/true-moozic-3632610172/`, che git ignora |
| `mod.info` | `id=TrueMoozic`, `versionMin=42.13`, `pack=tsarcraft_music`, `tiledef=tsarcraft_music 222`, autori «a_cow_says, hasteL, talismon». Nello stesso oggetto del Workshop c'è anche `TMMumble` (Mumble Remover) |

## 2. File e classificazione

31.400 righe di Lua (25 file client, 26 server, 18 shared, più le sottocartelle), 16 script, 73 texture, modelli,
suoni e traduzioni in 27 lingue. Per sottosistema:

| Sottosistema | File principali | Classificazione |
|---|---|---|
| **Jukebox: riconoscimento e conversione** | `shared/TMJukeboxDefs.lua`, `server/TMJukeboxServerCommands.lua`, `server/TMJukeboxServer.lua`, `client/TMJukeboxContext.lua` | **Idea da riprendere**, riscritta: la casella vanilla diventa sul server un `IsoThumpable` con contenitore |
| **Jukebox: riproduzione** | `client/TMJukeboxTick.lua` | **Idea da adattare**: emettitore nel mondo, volume per distanza, niente arresti decisi da un client lontano. **Da non riprendere**: è il client a decidere fine brano, play e stop |
| **Jukebox: finestra** | `client/RadioCom/TMJukeboxWindow.lua` (coda, coda salvata, ricerca, volume) | **Da riprendere solo nelle funzioni della specifica**: play, stop, avanti, indietro, scelta del brano, casuale, volume locale |
| **Umore** | `client/TMMoodTick.lua` | **Da non riprendere**: è calcolato sul client, ogni minuto di gioco, e conta anche l'infelicità e il tratto del fan |
| **Volume locale** | `client/TCClientVolume.lua`, `RadioWindowModules/TCRWMVolume.lua` | Idea da riprendere (volume solo per chi ascolta), riscritta |
| **Testo sopra l'apparecchio** | `client/TMDeviceSpeech.lua` | Incerto: carino, non chiesto. Fuori dalla V1 |
| Walkman, boombox, lettori CD portatili, HiFi, giradischi, cassette, vinili, custodie | `ISTCBoomboxAction` (client e shared, 3.600 righe), `HiFi*`, `SWTC*`, `TCRWM*`, `*Case*`, `TCCDStomp`, `InvContext*`, `TimedActions/*` | **Rimuovere** (non portato) |
| Autoradio, furgone, veicoli | `Vehicle*`, `HiFiVehicleTick`, `TrueMoozicStepVan*`, `scripts/vehicles` | **Rimuovere** |
| Casse e fili | `TMSpeaker*`, `TMSpeakerServerCommands`, `WireBundle_distribution` | **Rimuovere** |
| Graffi e pulizia dei CD | `InvContextCDClean`, campi `TMScratch*` | **Rimuovere** (V1: CD sempre leggibili) |
| Lista dei brani vietati | `TMBanList*` | **Rimuovere** |
| Tratto «truemoozicfan» e kit iniziale | `media/registries.lua`, `scripts/TM_Traits.txt`, `TCStartWithDevice.lua` | **Rimuovere** |
| Pacchetti musicali esterni | `SWTCAlbums.lua`, `TCMusicModDetector.lua` (album registrati da altre mod) | **Rimuovere**: il catalogo è uno, generato dal builder |
| Loot e spawn | `TCLootControl`, `TCSpawnController`, `*_distribution.lua`, `TCZombieLoot` | Idea da riprendere (aggiunte alle liste, mai liste sostituite), riscritta per i soli CD |
| Skype, computer, brani di pianoforte e di Pavarotti inclusi | `TCComputerSkype`, `sound/Tsar*`, `sound/TMComputer` | **Rimuovere**. Brani commerciali dentro la mod: un motivo in più per non copiare niente |

## 3. Dipendenze del jukebox di True Moozic

- `TMJukeboxDefs` dipende da `TCMusicDefenitions` (tabelle `TCMusic`, `GlobalMusic`, `SWTCCDAlbums`) e, per il
  volume, da `TCMusic.getListenVolume`/`worldVolKey`.
- `TMJukeboxTick` usa `TMJukeboxDefs`, `TMSpeech` (testo sopra), `TMMood` (umore), `TCMusic.getRandomCDSkipSound`
  (graffi).
- Il CD è un oggetto il cui tipo è una chiave di `SWTCCDAlbums` (`tracks[i].soundName`, `displayName`), riempita dai
  pacchetti musicali. I suoni sono script `sound` con `clip { file = media/sound/…, distanceMax = … }`.
- La rete passa da un solo canale, `sendClientCommand(player, "tmjukebox", "convert"|"touch", {x, y, z})`. Lo stato
  vive nella modData dell'oggetto (`md.tmJukebox`), che il client cambia e manda con `obj:transmitModData()`.

## 4. Noia e stress: le API reali della 42.21

Verificate nel jar con `javap` e nel Lua del gioco:

- `zombie.characters.CharacterStat`: `BOREDOM` registrata con minimo 0 e massimo 100, `STRESS` con minimo 0 e massimo 1
  (`UNHAPPINESS` da 0 a 100, non la tocchiamo). Esposta al Lua.
- `zombie.characters.Stats`: `get(stat)`, `set(stat, v)`, `add(stat, v)`, `remove(stat, v)`, `reset(stat)`,
  `isAtMinimum(stat)`. Il gioco toglie noia e stress **sul server** in `server/Farming/SFarmingSystem.lua`
  (`player:getStats():remove(CharacterStat.BOREDOM, …)`), e sul client in `shared/RadioCom/ISRadioInteractions.lua`.
- Tratti: `zombie.scripting.objects.CharacterTrait.DEAF` e `.HARD_OF_HEARING` (c'è anche `KEEN_HEARING`), letti con
  `player:hasTrait(CharacterTrait.DEAF)`.
- True Moozic toglie le statistiche **sul client** (`TMMood`, `EveryOneMinute`). **Da verificare nel gioco prima del
  Mood Engine**: se una `remove` fatta sul server arriva al client e non viene sovrascritta (c'è
  `zombie.network.packets.SyncPlayerStatsPacket`, che manda una maschera di statistiche). Se non arriva, il server
  calcola il beneficio e il client del giocatore lo applica, con un contatore contro i doppioni (FR-07).

## 5. Persistenza in True Moozic

- **Il jukebox vanilla è una casella senza contenitore** (verificato nei file del gioco: sprite `recreational_01_0`
  rivolto a E e `recreational_01_1` rivolto a S, `CustomName = Jukebox`, `GroupName = Oldies`, `IsMoveAble`, nessun
  `IsoType`). La classe Java `IsoJukebox` è il jukebox della 41 e nessuna casella la usa.
- True Moozic, **sul server**, toglie la casella (`square:transmitRemoveItemFromSquare`) e mette al suo posto un
  `IsoThumpable` con la stessa sprite e un contenitore (`setIsContainer(true)`, tipo `tm_jukebox`, capacità, funzione
  `AcceptItemFunction.TM_Jukebox`), con `AddSpecialObject` e `transmitCompleteItemToClients`. Il commento spiega
  perché sul server: un thumpable con contenitore creato dal client non viene salvato. La funzione di accettazione non
  si salva con l'oggetto: la riapplicano a ogni contatto. Il gioco limita la capacità a 100.
- Identità del jukebox: la posizione (`x_y_z`). Stato in `md.tmJukebox`: `isPlaying`, `volume`, `playIndex`, `queue`,
  `queueMode`, `queuePos`, `playSeq`, `shuffle`, `shuffleRand` (generatore Park-Miller condiviso), `savedQueues`.
- Brano: `uid` = id dell'oggetto CD (`item:getID()`) + numero della traccia. La playlist si ricostruisce dal contenuto
  del contenitore a ogni giro.
- API verificate nel jar della 42.21: `ItemContainer.setAcceptItemFunction(String)`, `setCapacity(int)`,
  `setType(String)`, `isItemAllowed`; `IsoThumpable(IsoCell, IsoGridSquare, String, boolean, KahluaTable)`;
  `IsoWorld.getFreeEmitter(float, float, float)`. Il gioco svuota `AcceptItemFunction` in
  `server/Items/AcceptItemFunction.lua` (`AcceptItemFunction = {}`), quindi la funzione va registrata dopo.

## 6. Audio: come si definisce e come si suona

- Ogni brano è uno script `sound` con un `clip { file = media/sound/<cartella>/<file>.ogg, distanceMax = … }`,
  `category`, `master = Ambient`. True Moozic porta a 500 caselle il `distanceMax` delle sue musiche.
- Riproduzione sul client: `getWorld():getFreeEmitter(x, y, z)`, `emitter:playSoundImpl(name, obj)` (o
  `playSound(name)`), `set3D(id, true)`, `setVolume(id, v)`, `isPlaying(id)`, `stopSound(id)`. Il volume per distanza
  lo calcola la mod: pieno fino a 80 caselle, zero a 100.
- **Nessun salto di posizione.** True Moozic non fa partire un brano a metà: chi entra nel raggio, arriva tardi o si
  ricollega lo sente **dall'inizio**, e due client possono sentire lo stesso brano in punti diversi. Fa due cose
  contro i problemi peggiori: con il `distanceMax` a 500 il motore non spegne la copia di chi si allontana, che resta
  in sincronia a volume zero; e un client oltre 45 caselle non fa mai avanzare il brano per tutti, perché per lui
  «non suona» può voler dire che il motore l'ha spento. Verificato nel jar della 42.21 che dal Lua non si può fare di
  meglio con un file: `FMODSoundEmitter$FileSound.setTimelinePosition` è vuoto; il salto esiste solo per gli eventi
  di FMOD Studio (`EventSound` con gli script `soundTimeline`); `fmod.javafmod.FMOD_Channel_SetPosition` c'è ma
  `javafmod` non è esposto al Lua (`LuaManager$Exposer`); `GameSoundClip` non ha un inizio spostato.
- **Il jukebox vanilla suona già qualcosa**: `tiledefinitions_noiseworks.patch.tiles` dà alle due caselle
  `AmbientSound = JukeboxAmbiance` (evento `World/Object/Jukebox`, in loop), suonato da
  `ObjectAmbientEmitters$AmbientSoundLogic` quando c'è corrente. Da sentire nel gioco: se è musica, si sovrappone. Un
  `IsoThumpable` con la stessa sprite probabilmente lo eredita (le proprietà sono della sprite): da verificare.
- La fine del brano la decide il client più vicino (`isPlaying` falso entro 45 caselle), che avanza lo stato e lo
  manda a tutti. Play, stop e salto li scrive il client nella modData. **Non è autoritativo sul server**: la
  specifica (FR-07, FR-13, FR-14) chiede il contrario.

## 7. Licenza e permessi

- Nella mod e nella pagina del Workshop **non c'è nessuna licenza** e nessun permesso di modifica o di
  ridistribuzione. La pagina dice che è il seguito di «True Music» della 41 di iBrRus. Contiene brani commerciali
  (arrangiamenti al pianoforte, Pavarotti).
- Quindi, come da specifica (§2.1 punto 7, Fase 0): **niente fork e niente ridistribuzione**. L'utente ha scelto il
  5 novembre 2026: implementazione nostra, True Moozic solo come lettura. Le idee generali (convertire la casella in
  contenitore sul server, il volume per distanza, non fidarsi di un client lontano) non sono codice. Per scrupolo
  `LICENSES.md` la citerà come fonte d'ispirazione, senza dire che è una sua fork.

## 8. Prove prima di rimuovere

Senza fork non c'è niente da rimuovere, e non abbiamo provato True Moozic nel gioco. Le prove di regressione sono
quelle della nostra implementazione (`TEST_PLAN.md`, da scrivere): prove Lua con `lupa` prima di ogni prova nel gioco,
poi single player, poi il server.

## Cosa cambia nelle proposte dopo l'audit

1. **Il contenitore**: come True Moozic, la casella vanilla diventa sul server un `IsoThumpable` con contenitore vero.
   Gli spostamenti di CD li valida il gioco sul server (finestra del bottino), con la nostra funzione di accettazione
   che conta i CD fino al massimo. Il codice è nostro. Prima proponevo una lista nella modData: questa soluzione è più
   solida contro i doppioni.
2. **La posizione nel brano** non ha una soluzione pronta. Le strade e le scelte sono in
   `docs/jukebox/DECISIONI.md`.
3. **Fine brano e comandi decisi dal server**: il server conosce la durata di ogni traccia (dal catalogo del builder),
   quindi sa da solo quando avanzare, senza ascoltare nessun client.
