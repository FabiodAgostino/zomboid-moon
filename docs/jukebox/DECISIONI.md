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
| Dove sta l'audio | Prima «su cirene, privato». Poi l'utente: «dobbiamo trovare un modo automatizzato per rendere tutto ciò sicuro» e «discord non deve centrare nulla». **Ora: cifrato (AES-256-GCM) in una pre-release `jukebox` di GitHub; la chiave la dà il server del gioco a chi entra, e il launcher la usa da solo.** Elenco dei CD pubblico, così chi non ha ancora la chiave entra lo stesso (senza musica). La licenza dei brani è dell'admin |
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
| 13 | Il suono vanilla `JukeboxAmbiance` | Sentirlo nel gioco. Se è musica, zittirlo mentre suona la nostra, se si può senza toccare i file del gioco |
| 14 | Benchmark con 8 client (AT-23) | Non abbiamo 8 client: misure con le sessioni vere e con la salute del server di ZomBOT, più una prova di carico del Lua in lupa |
| 15 | ffmpeg | Installato il 5 novembre 2026 con il sì dell'utente (winget, Gyan.FFmpeg.Essentials 9.0.1) |
| 16 | Il builder | Python (come `tools/kb` e `tools/silencermoon`), con ffmpeg e ffprobe. Musica sorgente fuori dal repo, per esempio in `%UserProfile%\Moon\musica` |
| 17 | Album e tracce nel gioco | Ogni album è un oggetto CD (`<modulo>.CD_<id>`), ogni traccia uno script `sound` generato; gli id non cambiano mai |

## Ancora aperto

Niente: le scelte tecniche sono in `TECHNICAL_DESIGN.md`.
