# Jukebox (Moon): le prove

## Automatiche (fatte il 5 novembre 2026)

```bash
python -m pytest -q tests/jukebox/test_lua.py        # Python con pytest, lupa e Pillow (la .venv di ZomBOT)
python -m pytest -q tests/jukebox/test_builder.py    # Python con pytest, Pillow, numpy e cryptography, più ffmpeg
```

- **Lua** (69, `lupa`, un Lua vero con il gioco imitato: solo i metodi che la mod usa, con i nomi della 42.21):
  conversione del jukebox una sola volta e solo vicino; solo i CD del catalogo e al massimo `MaxCDsPerJukebox`; la
  funzione di accettazione che sopravvive a `AcceptItemFunction = {}`; play dopo `LEAD_MS` e passaggio da solo al
  brano dopo e al primo; aprire non suona; scelta, avanti, indietro, stop; traccia inventata dal client ignorata;
  corrente che manca (stop, niente ripartenza); CD tolto mentre suona (traccia valida dopo, stop senza CD); CD
  diverso tolto (la traccia continua); jukebox sparito o casella non caricata; senza catalogo o spento; casuale
  deterministico e mai lo stesso brano due volte; troppi comandi; benvenuto con orologio e chiave; spawn solo admin
  e mai album archiviati; noia e stress (tasso × minuti / 60, solo minuti nel raggio, altro piano, prima dell'inizio,
  sordo 0, udito debole metà, due jukebox non si sommano, mai sotto zero, `syncPlayerStats`); bottino senza
  sostituire le liste; il client: orologio, pezzi all'ora del server, arrivo a metà al pezzo dopo, allontanarsi e
  tornare, brano nuovo e stop, catalogo diverso o mancante, chiave scritta solo se è una chiave, volume locale; la
  riga di stato; voce del tasto destro e pulsante admin; ogni file compila, ASCII, niente `next`/`xpcall`/
  `table.pack`/`table.unpack`/`os.clock`/`//`; testi IT ed EN; opzioni e predefiniti; `ZomBotMenu.lua` identico.
- **Builder** (20): errori della cartella della musica (id, anno, titolo lungo, campi sconosciuti, `../`, file
  mancante, formato, id doppi, collegamenti); numeri stabili, `--replace` e `--forget` obbligatori; stringhe Lua con i
  byte UTF-8; zip e cifratura sempre uguali, chiave sbagliata rifiutata; una build vera con ffmpeg (pezzi, catalogo,
  nomi, stesso risultato due volte, versione nuova se cambia un titolo, audio non ricifrato, errore che non tocca il
  pacchetto di prima); `install` e `publish` verso il server senza audio.
- **Launcher**: compilato (0 avvisi), e il codice dei pacchetti (`Core/Pack.cs`) provato con un programma che usa gli
  stessi file su cartelle finte e il pacchetto demo: senza chiave installa motore ed elenco dei CD e lo dice; con la
  chiave anche l'audio, identico byte per byte; chiave sbagliata, niente audio e l'avviso; dopo l'installazione tutto
  «Aggiornata» e niente da scaricare.

## Nel gioco (da fare, nell'ordine)

Single player con la musica demo (`README_ADMIN.md`, passo 4), poi il server con due client.

| AT | Prova | Come |
|---|---|---|
| 01 | Installazione dal launcher su un PC pulito | prima di pubblicare: `--sorgente` (una copia del repo con la mod «installabile») e `--pacchetto dist\<versione>` |
| 02 | Server con la mod, nessun errore | log del server all'avvio |
| 03 | Aprire un jukebox | tasto destro, «Jukebox»: finestra in italiano, la casella diventa contenitore una volta |
| 04 | CD con più tracce | tracce nell'ordine giusto |
| 05 | Cassette, vinili, altri oggetti | rifiutati dalla finestra del bottino, nessun oggetto perso |
| 06 | Due client vicini | stesso brano, stesso punto |
| 07 | Allontanarsi oltre 40 caselle e tornare | rientra al pezzo giusto, gli altri non si fermano |
| 08 | Entrare a brano iniziato | al pezzo dopo (al massimo 10 s di silenzio) |
| 09 | Volume a zero di un client | gli altri non cambiano |
| 10 | Staccare la corrente | stop per tutti, «Nessuna alimentazione», niente ripartenza |
| 11 | Togliere il CD che suona | traccia dopo, o stop senza CD |
| 12 | Un'ora di gioco nel raggio | noia −4, stress −0,02 (pannello di debug delle statistiche) |
| 13 | Fuori raggio, altro piano | niente |
| 14 | Due jukebox vicini | non si sommano |
| 15 | Deaf / Hard of Hearing | 0% / 50% |
| 16 | Creazione del personaggio | nessun tratto nuovo |
| 17 | Album nuovo col builder | CD nuovo senza scrivere Lua |
| 18 | Aggiornamento | CD e jukebox salvati restano |
| 19 | Launcher vecchio o catalogo vecchio | il launcher aggiorna; nel gioco «aggiorna il launcher» |
| 20 | Hash sbagliato o album.json rotto | il build si ferma (provato in automatico) |
| 21 | Riavvio del server con un jukebox acceso | CD al loro posto, jukebox spento |
| 22 | Spawn admin e bottino | finestra ZomBOT, «Jukebox»; CD nei negozi di musica |
| 23 | Carico | salute del server di ZomBOT con e senza jukebox accesi; un giro del server con 2 jukebox |
| 24 | Log | nessun errore Lua |

**Da guardare per primo**: se fra un pezzo e l'altro si sente un buco o un raddoppio. I pezzi si sovrappongono di
250 ms con una dissolvenza; se non basta si cambia `OVERLAP_MS` in `tools/jukebox/audio.py` (e si rifà il catalogo),
o si passa alla strada «brano successivo» di `DECISIONI.md`. Poi il suono d'ambiente del gioco (`JukeboxAmbiance`):
se il jukebox convertito lo suona ancora sopra la musica.

**Benchmark (AT-23)**: Moon non ha 8 client. Misura con la salute del server di ZomBOT (`/salute`) un'ora con e una
senza jukebox accesi, con i giocatori di una sera normale. Il lavoro del server è un controllo ogni 250 ms per jukebox
acceso, una lettura dei contenitori al secondo e un conto per giocatore al minuto di gioco: non dovrebbe vedersi.
