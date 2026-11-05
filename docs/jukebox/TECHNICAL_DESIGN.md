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
- La funzione di accettazione non si salva con l'oggetto (`ItemContainer.save` tiene tipo, capacità e oggetti, non
  `acceptItemFunction`), e senza il server lascia entrare qualsiasi cosa. La registriamo dopo
  `server/Items/AcceptItemFunction.lua` (che la svuota) e la rimettiamo sul contenitore ogni volta che il gioco carica
  la casella, sul server e su ogni client (`MapObjects.OnLoadWithSprite` sulle due sprite: il gioco chiama l'aggancio
  solo per gli oggetti con quelle sprite, niente scansioni), a ogni apertura e a ogni controllo del server.
- Il titolo nella finestra del bottino è `IGUI_ContainerTitle_jukeboxmoon` («Jukebox»).
- Il suono d'ambiente del gioco: la sprite ha `AmbientSound = JukeboxAmbiance`, e il gioco dà un emettitore d'ambiente
  a ogni oggetto con quella proprietà quando entra nel mondo (`IsoObject.addToWorld`), anche al jukebox convertito.
  Mentre suona la nostra musica ogni client lo toglie (`IsoChunk.removeObjectAmbientEmitter`; il gioco ferma ciò che
  non è più nell'elenco, `ObjectAmbientEmitters.stopNotPlaying`); torna quando la casella si ricarica.

### Lo stato

Decide tutto il server (FR-07, FR-13, FR-14). Il server tiene in memoria i jukebox accesi (`Server.active`, chiave
`x,y,z`): playlist del momento (tracce dei CD nell'ordine del contenitore), indice, traccia, CD, inizio e fine in ms
del suo orologio (`getTimestampMs`), casuale e stato del generatore. A ogni cambiamento manda a tutti
`state {key, x, y, z, on, seq, track, cd, start, ends, reason}` (`sendServerCommand`); a chi entra, alla richiesta
`hello`, la lista intera. Niente scansioni della mappa: i client conoscono i jukebox dal server.

In single player non c'è rete e `sendServerCommand` non manda niente (solo con `GameServer.server`, 42.21): il server
dà i messaggi al gioco locale con `triggerEvent("OnServerCommand", …)`, come fanno i file del gioco con
`if isServer() then … else … end`. Nell'altro verso il gioco li porta da solo (`SinglePlayerServer`).

- Avanti, indietro, scelta, casuale: comandi al server, controllati (vivo, stesso piano, entro `USE_TILES` caselle,
  oggetto giusto, CD e traccia presenti nel contenitore, al massimo 8 comandi ogni 4 s a giocatore; `hello` e `ping`
  al massimo uno al secondo ciascuno).
- Fine del brano: la decide il server dalla durata scritta nel catalogo, mai un client.
- Ogni brano parte `LEAD_MS` (1,2 s) dopo il comando o la fine del precedente, perché la notizia arrivi a tutti prima.
- Ogni secondo, per i jukebox accesi con la casella caricata sul server: oggetto ancora lì, corrente, contenuto. Un CD
  tolto con la sua traccia in corso fa passare alla traccia successiva; senza CD, stop («Nessun CD»).
- Corrente: `square:haveElectricity()` o `object:hasGridPower()`, come i suoni d'ambiente del gioco
  (`ObjectAmbientEmitters$AmbientSoundLogic`). Senza, stop («Nessuna alimentazione») e niente ripartenza.
- Casella non caricata sul server (nessuno vicino): il jukebox continua a suonare per conto suo con la playlist che
  conosce; i controlli riprendono quando la casella torna.
- Riavvio: lo stato non si salva (V1), quindi dopo un riavvio i jukebox sono spenti. Resta nell'oggetto (modData
  `jbm`) solo la scelta «casuale».
- Casuale: un generatore Park-Miller (16807, modulo 2^31 - 1) che sta nello stato del server, con un seme nuovo a
  ogni accensione (dall'ora del server e dalla posizione del jukebox); il brano dopo non è mai lo stesso.

### Il suono: pezzi da 10 s

Il Lua del gioco non può far partire un file a metà (`FMODSoundEmitter$FileSound.setTimelinePosition` è vuoto,
`javafmod` non è esposto). Quindi il builder taglia ogni brano in pezzi da `segmentMs` (10 s): il pezzo `k` va da
`k * 10 s` a `(k + 1) * 10 s + overlapMs` (250 ms), con una dissolvenza in uscita negli ultimi 250 ms e una in entrata
nei primi 250 ms del pezzo dopo. Due pezzi vicini si sovrappongono per 250 ms sullo stesso audio: se il pezzo dopo
parte con un fotogramma di ritardo non c'è silenzio.

Ogni pezzo è uno script `sound JukeboxMoon_T<traccia>_S<pezzo>` con
`clip { file = media/sound/jukeboxmoon/t<traccia>/s<pezzo>.ogg, distanceMin, distanceMax }`, `master = Ambient` (il
cursore «Ambiente» del gioco: il volume della musica del gioco resta libero).

I pezzi sono **mono**, 44,1 kHz. Il gioco suona un file decodificandolo tutto in memoria e non lo libera più fino
alla chiusura (`FMODManager.loadSound`: `FMOD_System_CreateSound` con il solo `FMOD_3D`, tenuto in `fileToSoundMap`;
verificato nel jar della 42.21, nessuno chiama `FMOD_Sound_Release`). Ogni minuto di musica diversa che un giocatore
sente resta lì, circa 5 MB in mono (10 in stereo): ascoltare in una sessione tutti i CD di Radio Voices (89 minuti) ne
tiene circa mezzo GB, che torna libero chiudendo il gioco. Riascoltare un brano non costa niente. E il jukebox è un
suono nel mondo: da 2 caselle in su il gioco lo suona tutto in 3D (`FileSound`, `FMOD_Channel_Set3DLevel`), dove uno
stereo arriva comunque da un punto solo. Decodificare un pezzo da 10 s richiede una decina di millisecondi.

Il client (`client/JukeboxMoon/Player.lua`), a ogni tick, per ogni jukebox acceso entro `HEAR_TILES` (40 caselle):
calcola l'ora del server (`getTimestampMs() + offset`), il pezzo del momento e lo fa partire
(`getWorld():getFreeEmitter(x, y, z)`, `playSoundImpl(nome, false, nil)`, `set3D`, `setVolume`). **Non
`playSound`**: su un client manda il suono anche agli altri client vicini (`GameClient.PlayWorldSound` per un
emettitore senza oggetto, 42.21), che suonano già il loro pezzo e lo sentirebbero due volte, in ritardo.
`playSoundImpl` a tre argomenti è l'unica versione con quel numero di argomenti (nessuna scelta ambigua per Kahlua) e
suona solo qui. Se arriva a metà di un pezzo aspetta il successivo (al massimo 10 s di silenzio): così chi arriva
tardi, chi si riavvicina e chi rientra sente lo stesso punto degli altri (FR-03, AT-07, AT-08). Fuori dal raggio non
suona niente e non decide niente (AT-09). Il volume è del giocatore (cursore della finestra, salvato solo sul suo PC
un secondo dopo l'ultimo movimento).

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
In MP con il controllo dei file acceso (`DoLuaChecksum`, di base sì) il gioco non fa nemmeno entrare chi ha un
catalogo diverso: confronta i file Lua e gli script (`ChecksumPacket`, `ScriptManager.getChecksum`), e
`CatalogData.lua` e gli script dei CD sono fra questi. Per questo il catalogo pubblico è obbligatorio nel launcher e
va aggiornato prima di entrare; l'audio non entra nel controllo.

Gli id numerici (`key`) di album e tracce li assegna il builder e li ricorda in `jukebox.lock.json`, nella cartella
della musica: non cambiano mai, e un album tolto diventa «archiviato» (resta l'oggetto, niente bottino né spawn).

### I CD del gioco

Il gioco ha un solo oggetto CD, `Base.Disc_Retail`, con una registrazione (`item:getMediaData():getId()`, uno dei
69 `RecMedia` di categoria `CDs`). Un album del catalogo con `media` invece di `item` è un CD del gioco:
`Catalog.albumOf` lo riconosce dalla registrazione, e il jukebox lo accetta solo se il catalogo ce l'ha. Per questi
album il builder non scrive oggetti, icone né nomi; non entrano nel bottino (ci sono già); l'admin li crea come
`Base.Disc_Retail` con `item:setRecordedMediaData(getZomboidRadio():getRecordedMedia():getMediaData(id))`.

L'audio viene da Radio Voices (`tools/jukebox/radiovoices.py`): ogni riga del gioco ha la sua chiave (il testo
inglese normalizzato come fa `RadioVoices.normalize`); le canzoni (`RadioVoices.songs`) elencano le righe che cantano
e hanno la canzone intera in un suono (`starts[1]`, `RV_s_<id>_0`). Le tracce di un CD sono le canzoni che coprono
almeno tre delle sue righe **diverse** (tutte, se il CD ne ha meno: Eurodance '92 ne ha due), la più ampia per prima
(due versioni di una canzone hanno le prime righe in comune), in ordine di inizio. Le righe ripetute contano una volta:
«Electronic beats» è sei righe di due CD, e una canzone che canta solo quella non deve finire nell'altro. Un CD senza
canzoni ma con le righe lette (audiolibri, Bibbia, storia) è una traccia sola, le frasi una dopo l'altra con 0,6 s di
pausa. L'importatore prepara tutto in una cartella a parte e poi sostituisce solo le cartelle `albums/cd-*` che ha
fatto lui (hanno il file `.import-radiovoices`): un errore a metà non tocca niente, e un album dell'admin che si chiama
`cd-…` resta dov'è.

### Bottino e spawn

- `server/JukeboxMoon/Distributions.lua`, `OnPreDistributionMerge`: i CD si aggiungono alle liste del gioco che hanno
  già CD (`CrateCompactDiscs`, `MusicStoreCDs`, `ElectronicStoreMusic`, `BandPracticeInstruments`,
  `MovieRentalShelves`, `LivingRoomShelf*`, `RecRoomShelf`, `BedroomSidetable*`, `BedroomDresser*`), con un peso per
  lista diviso fra gli album secondo `lootWeight`. Mai una lista sostituita.
- Spawn admin: il pulsante «Jukebox» della finestra ZomBOT (`ZomBotMenu`, `extra`); il server ricontrolla il ruolo
  (`getRole():hasAdminPower()` o `CanSetupNonPVPZone`), al massimo 20 CD per volta, solo album non archiviati e non
  unici.

### Il CD unico

Un album con `"unique": {"from": "runner", "oneIn": 300}` in `album.json` è un CD solo in tutta la storia del server
(decisione dell'utente, `DECISIONI.md` 18; oggi «Love storii...»). Non è nel bottino e gli admin non lo creano
(`Catalog.activeAlbums` lo lascia fuori): un secondo esemplare non sarebbe unico. Il builder scrive nel catalogo
`unique = { from, oneIn, jsonName, jsonArtist }`, con nome del CD e artista già pronti per il JSON (ASCII, `\uXXXX`).
**Uno alla volta** (scelta dell'utente, `DECISIONI.md` 18): in gioco c'è un solo CD unico, il primo per numero
d'album (l'ordine in cui gli album entrano nel catalogo) non ancora trovato. Entra in gioco (`since`, secondi unix)
all'avvio del server o quando quello di prima viene trovato; gli altri aspettano il loro turno, ognuno con il suo
`oneIn`. Un CD che torna da tirare perché nessuno ha saccheggiato il cadavere tiene il suo `since`.

Il lavoro è in `server/JukeboxMoon/Unique.lua` e, per dire al server chi lo prende, in `client/JukeboxMoon/Finder.lua`.
Il server non fa niente da solo: nessun controllo periodico (scelta dell'utente, `DECISIONI.md` 18). Verificato nel jar
e nel Lua della 42.21:

- **La caduta.** `IsoZombie.onKilled` gira sul server: riempie l'inventario dello zombie, lancia `OnZombieDead`, poi
  fa il cadavere da quell'inventario (`DoDeath`). Un CD aggiunto durante l'evento è sul cadavere. Chi l'ha ucciso è
  `getAttackedBy()` (come conta le uccisioni ZomBOT, `ZomBotKills.lua`); un corridore ha `getWalkType()` che comincia
  per `sprint` (il valore del server, che lo manda ai client in `ZombiePacket`). Solo per un corridore ucciso da un
  giocatore, non in fiamme (il cadavere brucerebbe il CD), una volta per zombie (le morti nel fuoco lanciano l'evento
  due volte), e solo finché il CD aspetta: `ZombRand(oneIn) == 0`.
- **Trovato: lo dice la mod di chi lo prende.** Prendere un oggetto è un'azione del client
  (`media/lua/client/TimedActions/ISInventoryTransferAction.lua`): in multiplayer il client chiama
  `createItemTransaction`, il server sposta l'oggetto in Java senza un evento Lua, e quando arriva
  `ItemTransactionPacket` il client esegue `perform()` (`transferItem` lì gira solo senza rete). `Finder.lua` avvolge
  `perform()` di `ISInventoryTransferAction` e di `ISGrabItemAction` (da terra), guarda gli oggetti del lotto
  (`queueList[1].items`) e, per un CD unico, manda al server `taken {album, item}`, una volta (di nuovo solo dopo 5 s).
  La mod è obbligatoria: ce l'ha ogni client. Il server controlla **una volta, a quel messaggio**, solo se il CD è
  «caduto»: il giocatore lo porta (`containsTypeRecurse`, anche nelle borse), oppure è entro 5 caselle da dove è caduto
  e il CD non è più su un cadavere lì (due caselle intorno): l'ha messo in una cassa, in un'auto, per terra. Allora è
  trovato da lui. I messaggi hanno il limite degli altri comandi (8 ogni 4 s).
- **Il cadavere che nessuno saccheggia**, senza sorveglianza: il CD resta «caduto», con il posto e l'ora del mondo
  (`getGameTime():getWorldAgeHours()`). Può ricadere solo se un corridore lo tira di nuovo (1 su `oneIn`) **e** dalla
  caduta è passato il tempo di rimozione dei cadaveri del server (`SandboxVars.HoursForCorpseRemoval`, ore di gioco,
  216 di base) senza che nessuno l'abbia segnalato: il cadavere a quel punto non c'è più. Con 0 o meno (i cadaveri
  restano) non ricade mai. Il controllo si fa solo in quel momento.
- **Il rischio**: uno spostamento che passasse da una strada che la mod non vede (un'altra azione, un'altra mod), seguito
  da quel tempo e da un nuovo tiro fortunato, farebbe una seconda copia. Le strade del gioco per prendere un oggetto
  da un cadavere o da terra sono quelle due.
- **Salvato** nel mondo (ModData globale `JukeboxMoon.unique`, per numero dell'album): `state` (`waiting`, `dropped`,
  `found`), `since`, nome e artista (un album tolto dal catalogo tiene la sua riga), dove e quando (secondi e ore del
  mondo) è caduto, chi l'ha trovato.
- **Per ZomBOT**, `Zomboid/Lua/jukeboxmoon_unique.json`, riscritto intero all'avvio (`OnInitGlobalModData`) e a ogni
  cambiamento. Il contratto è di ZomBOT (zomboid-discord, `zombot.jukebox`): non cambiarlo da una parte sola.

  ```json
  {"v":1,"unique":[{"key":"62","name":"CD: Love storii...","artist":"Prince","since":1762300000,"found":null}]}
  ```

  Una riga per ogni CD unico di sempre, per numero dell'album, per sempre. `since`: quando è entrato in gioco,
  `null` finché aspetta il suo turno; al massimo una riga ha `since` e non `found` (quello in gioco).

  Da trovato, `found` è `{"user":"<account>","character":"<nome e cognome>","at":<secondi unix>,"from":"runner","test":false}`.
  ZomBOT annuncia in #zombot ogni CD che entra in gioco («oggetto unico», senza dire quale; non quelli già in gioco
  la prima volta che legge il file) e una volta per `key` quello trovato («è stato trovato un CD unico…»), mai con
  `test: true`: in single
  player e in un gioco avviato con `-debug`, dove per provarlo il CD cade dal primo corridore.

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
  sull'impronta dello zip: lo stesso album dà lo stesso file, due album diversi mai lo stesso nonce. Il nome viene
  dall'impronta del file cifrato: con un'altra chiave è un altro nome, e GitHub riceve il file nuovo. Un album per file
  perché una release di GitHub tiene al massimo mille allegati, e i pezzi sono migliaia.
- `manifest.json`, pubblico: `catalogVersion` (i primi 16 caratteri dello SHA-256 della lista di tutti i file, dei
  dati degli album, del motore e della chiave), `packageVersion` (versione del motore), `keyId` (i primi 16 caratteri
  dello SHA-256 della chiave), il catalogo pubblico e gli album, ognuno con numero, id, nome dell'allegato, byte,
  SHA-256 dell'allegato e, per ogni file dentro, percorso, byte e SHA-256.

La stessa sorgente con gli stessi strumenti dà gli stessi file (`-fflags +bitexact`, zip con date fisse, nonce
derivato), e i pezzi già fatti si riusano se brano e parametri non cambiano (quelli che nessun brano usa più si
tolgono dopo ogni build). Si costruisce in `dist/.staging`, un album alla volta (l'audio di tutto il catalogo non è
mai in memoria insieme), si verifica, poi si scrivono la chiave e `jukebox.lock.json` e solo alla fine il pacchetto
prende il suo nome: un errore non lascia mai un pacchetto a metà, né un pacchetto senza i numeri che ha usato. Una
cartella della musica che ha la chiave e non i numeri, o i numeri e non la chiave, è stata costruita e ha perso un file:
il builder si ferma invece di dare numeri nuovi (i CD nei salvataggi suonerebbero un altro album) o una chiave nuova.

### La chiave

- 32 byte casuali, scritti dal builder la prima volta in `jukebox.key`, nella cartella della musica dell'admin (fuori
  dal repo). `publish` la copia sul server in `Zomboid/Lua/JukeboxMoon_server_key.txt`.
- Il server la legge all'avvio e la manda nel benvenuto (`key {key, id}`) a ogni giocatore collegato: in MP solo chi
  ha passato l'accesso del server; in single player l'admin che prova.
- La mod del giocatore la scrive in `Zomboid/Lua/JukeboxMoon_key.txt` (solo se è una chiave e se è cambiata); il
  launcher la legge da lì e controlla che sia quella del catalogo (`keyId`). La prima sessione su Moon di un
  giocatore nuovo è senza musica; dalla seconda c'è.
- Una chiave che gira fuori dal gruppo apre la musica a chi la ha: `build --new-key` ne fa una nuova e ricifra tutto;
  la vecchia resta accanto come `jukebox.key.<id>`. L'audio installato sul PC è in chiaro (il gioco deve leggerlo):
  la cifratura protegge la musica pubblicata, non i file di chi gioca.

### GitHub

- Release `jukebox` del repo, **pre-release**: il launcher prende per sue solo le release normali
  (`Sources.cs`: `!Draft && !Prerelease`) e non la mostra fra le novità. Allegati: `manifest.json` (sostituito a ogni
  pubblicazione, per ultimo, riprovato se il caricamento non riesce), `catalog-<hash>.zip` e `a<album>-<hash>.jbm`
  (per contenuto: un file già caricato per intero, con gli stessi byte e lo stesso SHA-256 che GitHub dice, non si
  ricarica). Prima di caricare, `publish` confronta i numeri degli album con il `manifest.json` pubblicato e rifiuta
  un pacchetto che dà a un album il numero di un altro. `publish --prune` toglie gli allegati che né il pacchetto né
  gli ultimi tre manifest usano (con `--dry-run` dice quali).
- Il launcher li scarica da `https://github.com/<repo>/releases/download/jukebox/<nome>`, senza API.

### Il server

`publish` copia, via ssh su cirene, il motore (`mods/JukeboxMoon` del repo) e il catalogo pubblico in
`~/server/zomboid/live/Zomboid/mods/JukeboxMoon` e la chiave. La copia nuova viaggia in `Zomboid/JukeboxMoon-publish/new`
e quella di prima resta in `Zomboid/JukeboxMoon-publish/old`: **mai dentro `mods`**, perché il gioco segna id →
cartella per ogni `mod.info` che trova (`ZomboidFileSystem`, `modIdToDir.put`, 42.21) e con due cartelle della stessa
mod potrebbe caricare la vecchia. Il server li carica al riavvio. L'audio sul server non serve.

### Launcher

- `mods.json`: la voce `jukebox-moon` installa `mods/JukeboxMoon` in `{zomboid}/mods/JukeboxMoon` con `mirror`, e
  `pack` dice la release del catalogo. I file del catalogo entrano nel piano della mod come quelli del repo: lo stesso
  confronto byte per byte, e il `mirror` non li tocca.
- Il catalogo pubblico è obbligatorio come il motore: GIOCA lo installa prima di avviare il gioco. L'audio no: senza
  chiave la scheda dice «La musica arriva dopo la prima volta su Moon».
- Si scaricano solo gli album che mancano o sono cambiati, si verifica l'impronta dell'allegato, si decifra (la chiave
  sbagliata non passa il tag di GCM) e si verifica ogni file prima di installarlo (`Core/Pack.cs`, launcher 1.0.3).
  Le impronte dei file installati si ricordano per percorso, dimensione e data (`Core/HashCache.cs`, salvate dopo
  ogni controllo): centinaia di MB non si rileggono a ogni avvio.
- Il pacchetto si rilegge a ogni installazione (`ModPlan.Base`): togliere e rimettere la mod, o riprovare dopo un
  errore, nella stessa sessione funziona, e gli album già scaricati non si riscaricano.
- Se il pacchetto non si legge (GitHub irraggiungibile la prima volta, elenco rovinato, un file bloccato), la mod resta
  con i file del repo e un avviso, e i file del catalogo e della musica già installati **restano** (`KeepExtras`: il
  `mirror` non li toglie). L'elenco ha 15 secondi per arrivare, un album si ferma dopo 30 secondi senza dati: il
  launcher non resta mai appeso. Le altre mod vanno avanti comunque.
- Per provare un pacchetto prima di pubblicarlo: `MoonLauncher.exe --pacchetto <dist>\<versione>` (con `--sorgente`
  su una copia del repo dove la mod è «installabile»).
