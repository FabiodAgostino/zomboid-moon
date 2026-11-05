# Jukebox: decisioni

Le decisioni aperte della specifica (v1.0, 5 novembre 2026) e quelle nate dall'audit (`UPSTREAM_AUDIT.md`).
Una proposta vale finché l'utente non dice altro.

## Prese con l'utente (5 novembre 2026)

| Punto | Decisione |
|---|---|
| Dove vive il progetto | `zomboid-moon`, ramo `claude/jukebox` (worktree `.claude/worktrees/jukebox`): mod in `mods/<ID>`, builder in `tools/jukebox/`, prove in `tests/jukebox/` (pytest + lupa), documenti in `docs/jukebox/` |
| True Moozic | Scaricata con steamcmd, solo da leggere (in `originale/`, che git ignora) |
| Fork o codice nostro | **Codice nostro.** Di True Moozic nel pacchetto non entra niente: né codice, né suoni, né texture, né testi. La mod non ha una licenza che ne permetta la ridistribuzione |
| La musica | **Audio a parte.** Il repo non contiene mai brani. L'audio è un pacchetto suo, con manifest SHA-256 per file; il launcher lo scarica solo quando cambia, file per file (serve una modifica al launcher). Il server riceve la mod senza audio |
| Chi arriva a brano iniziato | **Pezzi da circa 10 s.** Il builder taglia ogni brano; chi arriva, si riavvicina o rientra entra al pezzo successivo, e tutti sentono lo stesso punto. **Prima una prova nel gioco** con una mod minima che suona tre pezzi di fila: se la pausa fra i pezzi si sente, si passa a «brano successivo» (chi arriva tardi aspetta il brano dopo) |
| Mod ID | **`JukeboxMoon`**, nome «Jukebox (Moon)». Lo stesso per il modulo degli oggetti |
| Dove sta l'audio | Prima «su cirene, privato». Poi l'utente: «dobbiamo trovare un modo automatizzato per rendere tutto ciò sicuro» e «discord non deve centrare nulla». **Ora: cifrato (AES-256-GCM) in una pre-release `jukebox` di GitHub; la chiave la dà il server del gioco a chi entra, e il launcher la usa da solo.** Elenco dei CD pubblico, così chi non ha ancora la chiave entra lo stesso (senza musica). La licenza dei brani è dell'admin. Poi, lo stesso giorno, la chiave anche come codice personale dalla pagina dal vivo (riga «Il codice della musica») |
| I CD del gioco | Richiesta dell'utente (5 novembre 2026): suonare i CD del gioco con l'audio di Radio Voices (Workshop 3828360540, Espaidi). «Per il permesso poi ci penso io, per le canzoni vere puoi tenerle tanto il server è privato... basta che non finisce su git». **Fatto**: importatore nel builder, il jukebox accetta i dischi del gioco dalla loro registrazione; audio solo nella cartella della musica e cifrato su GitHub |
| Il codice della musica | Richiesta dell'utente (5 novembre 2026): la prima sessione senza musica, con il launcher da riaprire, non va; deve essere automatico. **Il launcher chiede una volta sola un codice personale** che la pagina dal vivo di ZomBOT (scheda «Musica»; il link lo manda ZomBOT, solo a te, con `/scheda` su Discord) mostra a ogni giocatore. Dal codice ricava la chiave, la scrive nel file dove la scrive il gioco (`Zomboid/Lua/JukeboxMoon_key.txt`, «il launcher se lo ricorda») e **scarica la musica prima di avviare il gioco**. «Più tardi» resta: il gioco parte senza musica, come prima. Discord porta solo il link alla pagina, mai il codice. Contratto «moon-music-code v1» del launcher 1.0.4; dalla sera i codici sono monouso (riga sotto) |
| Codici monouso (sera del 5 novembre 2026) | Richiesta dell'utente: il codice si deve consumare. **Un codice per account Discord, valido una volta sola**; altri li fa un admin con `/codicemusica`, anche loro monouso. Il codice non contiene più la chiave: è un gettone casuale che tiene il bot di ZomBOT, e il launcher 1.0.5 lo **riscatta online** (`POST https://zombot.cirene.eu/api/musica/riscatta`, indirizzo in `mods.json`) e scrive la chiave che ZomBOT risponde. La finestra lo dice: «Il codice vale una volta sola: il launcher se lo ricorda su questo PC. Per un altro PC chiedi un codice nuovo a un admin.» Nello stesso launcher, dalla segnalazione di Zaskor: **GIOCA chiede sempre il codice** quando manca l'audio e non c'è una chiave valida, scarica sempre l'audio mancante quando la chiave c'è, e dice quando l'elenco degli asset non si legge, invece di avviare il gioco senza musica. Contratto in `TECHNICAL_DESIGN.md`, «Il codice della musica» |
| Le proposte qui sotto | **Tenute tutte** (risposta dell'utente). Si cambiano quando vuole |

## Proposte tenute

| # | Punto | Proposta |
|---|---|---|
| 1 | Obbligatoria | Sì. Con la mod in `Mods=` il client deve averla per entrare: `required: true` nel launcher, come ZomBOT (Moon) |
| 2 | Valori (FR-06, §8.1) | Quelli della specifica: 10 caselle sullo stesso piano, noia 4/ora di gioco, stress 0,02/ora, valutazione ogni 10 minuti di gioco, Deaf 0%, Hard of Hearing 50%, benefici non cumulabili, 20 CD (1–100), casuale permesso, nessuna ripartenza dopo un'interruzione di corrente o un riavvio |
| 3 | Coda manuale | Niente coda in V1: scelta del brano, avanti, indietro, casuale |
| 4 | Il contenitore | Come True Moozic (l'idea, non il codice): sul server la casella vanilla diventa un `IsoThumpable` con contenitore vero; i CD si mettono e si tolgono dalla finestra del bottino del gioco, che il server valida; la nostra funzione di accettazione prende solo i nostri CD, fino al massimo |
| 5 | Jukebox raccolto o distrutto con CD dentro | Fatto diversamente: il gioco stesso non lascia raccogliere un contenitore non vuoto (`isObjectNoContainerOrEmpty`, verificato nel suo Lua). Se il jukebox sparisce in altro modo la musica si ferma («Si è fermato: il jukebox non c'è più») |
| 6 | Chi lo usa | Chiunque sia a 2–3 caselle, anche fuori da un rifugio |
| 7 | Comandi | Decide tutto il server: play, stop, avanti, indietro, scelta, casuale, fine del brano (conosce la durata di ogni traccia dal catalogo). I client suonano e basta |
| 8 | Voce sul jukebox | Una voce propria «Jukebox» nel tasto destro sul jukebox, come le azioni del gioco sugli oggetti |
| 9 | Spawn admin | Un pulsante «Jukebox» nella finestra di ZomBOT (gli `extra` di `ZomBotMenu`, come SilencerMoon): scelta dell'album e quantità, al massimo 20 alla volta, controllato sul server |
| 10 | Loot | Acceso e raro, solo aggiunte alle liste dei contenitori adatti (negozi di musica, camere, scaffali), scelti sulle distribuzioni della 42.21 |
| 11 | Album tolti dal catalogo | Mai tolti dal pacchetto in automatico: l'oggetto resta e diventa «archiviato» (niente loot, niente spawn) |
| 12 | Lingue | Italiano, con l'inglese di riserva |
| 13 | Il suono vanilla `JukeboxAmbiance` | Fatto senza toccare i file del gioco: mentre suona la nostra musica ogni client toglie l'emettitore d'ambiente del jukebox convertito (`IsoChunk.removeObjectAmbientEmitter`, verificato nel jar 42.21). Da sentire nel gioco |
| 14 | Benchmark con 8 client (AT-23) | Non abbiamo 8 client: misure con le sessioni vere e con la salute del server di ZomBOT, più una prova di carico del Lua in lupa |
| 15 | ffmpeg | Installato il 5 novembre 2026 con il sì dell'utente (winget, Gyan.FFmpeg.Essentials 9.0.1) |
| 16 | Il builder | Python (come `tools/kb` e `tools/silencermoon`), con ffmpeg e ffprobe. Musica sorgente fuori dal repo, per esempio in `%UserProfile%\Moon\musica` |
| 17 | Album e tracce nel gioco | Ogni album è un oggetto CD (`<modulo>.CD_<id>`), ogni traccia uno script `sound` generato; gli id non cambiano mai |
| 18 | Il CD unico (5 novembre 2026) | L'utente: «dobbiamo fare che il drop di love storii sia raro e solo in un 5% dei runner e poi una volta che viene trovato non può essere ritrovato», con l'avviso di ZomBOT in #zombot quando viene trovato. Deciso poi con l'utente: **1 su 300 corridori uccisi da un giocatore** (il 5% per corridore lo farebbe uscire in un giorno), l'avviso dice personaggio e account. «Love storii...» non è nel bottino né fra i CD degli admin. «Trovato» vuol dire preso da un giocatore. Un controllo del server ogni minuto è sembrato all'utente «decisamente eccessiva questa cosa»: **lo dice la mod di chi lo prende** (obbligatoria, ce l'ha ogni client) e il server controlla una volta a quel messaggio. Un CD che nessuno prende può ricadere solo dopo il tempo di rimozione dei cadaveri del server, con un nuovo 1 su 300. Poi l'utente: «Dobbiamo fare in modo che questa roba del loot dei dischi speciali non sia solo per love-storii ma anche per altri dischi che metterò in futuro dopo che sarà trovato love storii»: **uno alla volta**, nell'ordine in cui vengono aggiunti, ognuno con il suo `oneIn`; ZomBOT annuncia ogni CD che entra in gioco come «oggetto unico» senza dire quale. Un CD mai raccolto non deve fermare la fila (l'utente: «Dobbiamo risolvere questo problema»): ricade dopo il tempo di rimozione dei cadaveri, o dopo 7 giorni di gioco se il server non li toglie, e una copia vecchia trovata dopo viene tolta. Nessun segnale a chi uccide il corridore con il CD (l'utente: «No, resta segreto»): si trova solo saccheggiando. Progetto e rischio in `TECHNICAL_DESIGN.md`, «Il CD unico» |

## Ancora aperto

Niente: le scelte tecniche sono in `TECHNICAL_DESIGN.md`.
