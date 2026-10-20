# Moon

Tutto quello che serve sul tuo computer per giocare a **Project Zomboid** (Build 42) sul server **RiversideMoon**, in un solo file da lanciare: **`installa.bat`**.

Installa due cose:

1. **La mod dei silenziatori** «Simple Suppressors (Moon IT)»: è la mod Simple Suppressors di Kiidxatlas, tradotta in italiano e con alcuni bug corretti (vedi [Cosa cambia rispetto all'originale](#cosa-cambia-rispetto-alloriginale)). Il server la usa, quindi **senza questa mod non puoi entrare**.
2. **Le finestre di ZomBOT per gli admin**, per gestire le scorte delle basi. Le vede solo chi è admin sul server: per tutti gli altri non fanno niente, quindi le installa chiunque e non ci si pensa più.

---

## Installazione (2 minuti)

1. **Scarica il pacchetto.** In questa pagina, in alto, premi il pulsante verde **`<> Code`** e poi **`Download ZIP`**.
2. **Estrai lo ZIP.** Tasto destro sul file scaricato, **«Estrai tutto...»**, poi **«Estrai»**. Non lanciare `installa.bat` da dentro lo ZIP senza estrarlo: non troverebbe i file da installare.
3. **Chiudi Project Zomboid**, se è aperto.
4. **Doppio clic su `installa.bat`** nella cartella estratta.
   - Se compare la finestra blu **«Windows ha protetto il PC»**, premi **«Ulteriori informazioni»** e poi **«Esegui comunque»**; se invece compare **«Avviso di sicurezza»**, premi **«Esegui»**. Windows avvisa così per i file scaricati da internet che non hanno una firma: `installa.bat` è testo semplice e chiunque può leggerlo prima (tasto destro, «Modifica»).
5. Premi **`I`** (Installa o aggiorna) e aspetta il messaggio **«Tutto pronto»**. Premi un tasto per chiudere.
6. **Avvia Project Zomboid ed entra su RiversideMoon** come sempre. Non devi attivare niente nel menu Mod: in multiplayer le mod le attiva il server.

Il file trova da solo il gioco nelle librerie di Steam, anche su un altro disco. Se non ci riesce te lo dice: in quel caso **trascina la cartella `ProjectZomboid` sopra `installa.bat`** (di solito è in `...\Steam\steamapps\common\ProjectZomboid`; da Steam: tasto destro sul gioco, «Gestisci», «Sfoglia i file locali»).

## Aggiornare

Quando esce una nuova versione: scarica di nuovo lo ZIP, estrailo, doppio clic su `installa.bat` e premi **`I`**. La versione vecchia viene sostituita del tutto, non serve disinstallare prima.

## Disinstallare

Doppio clic su `installa.bat` e premi **`D`**. Toglie la mod e le finestre di ZomBOT. Ricorda che senza la mod non puoi entrare su RiversideMoon.

## Cosa installa, esattamente

| Cosa | Dove |
| --- | --- |
| La mod dei silenziatori (cartella `SimpleSuppressorsMoon`) | `C:\Users\<il tuo nome>\Zomboid\mods\` |
| `ZomBotData.lua` | `<cartella del gioco>\media\lua\shared\` |
| `ZomBotStockUI.lua` | `<cartella del gioco>\media\lua\client\` |

Non tocca nient'altro: i salvataggi, le impostazioni e le altre mod restano come sono.

## Problemi frequenti

**«Non riesco a scrivere nella cartella del gioco».** Chiudi il gioco e riprova. Se non basta: tasto destro su `installa.bat`, **«Esegui come amministratore»**.

**Entrando nel server il gioco dice che manca una mod, o che le mod non corrispondono.** Rilancia `installa.bat` e premi `I`: probabilmente sul server c'è una versione più nuova. Se il problema resta, scrivi nel canale del server su Discord.

**Ero iscritto alla mod originale Simple Suppressors sul Workshop.** Puoi lasciarla: sul server si usa questa. In una partita in single player però non attivarle tutte e due insieme.

**Voglio usare i silenziatori anche in single player.** Dal menu principale: **Mod**, attiva **«Simple Suppressors (Moon IT)»**, poi crea una nuova partita.

**Ho un Mac o Linux.** `installa.bat` funziona solo su Windows. A mano: copia la cartella `mods/SimpleSuppressorsMoon` in `~/Zomboid/mods/`. Le finestre di ZomBOT servono solo agli admin: copia `zombot/shared/ZomBotData.lua` e `zombot/client/ZomBotStockUI.lua` in `media/lua/shared/` e `media/lua/client/` dentro la cartella del gioco.

## Per gli admin: le finestre di ZomBOT

ZomBOT è il bot Discord del server. Conta le scorte delle basi (cibo, munizioni, medicine, libri...) e le mostra su Discord, per esempio con `/scorte` e `/basi`. Con queste finestre gli admin decidono, dentro il gioco, quali basi ci sono e cosa tenere d'occhio:

- **tasto destro sul pavimento, «ZomBOT: basi...»**: crea, modifica o elimina le basi, disegnandole sulla mappa;
- **tasto destro sul pavimento dentro una base, «ZomBOT: scorte di questa base»**: le scorte tracciate, con la possibilità di smettere di tracciarne una;
- **tasto destro su un oggetto, «Aggiungi a scorta»**: tiene d'occhio quell'oggetto nella base, con le soglie «presente», «scarseggia» e «critico»;
- **«Controlla i libri» / «Controlla le riviste»**: quali libri delle abilità e quali riviste di ricette mancano nella base.

Il server accetta queste modifiche solo dagli admin: per chi non lo è, i menu non compaiono e il file non dà nessun potere.

## Cosa cambia rispetto all'originale

La mod di partenza è **[Simple Suppressors](https://steamcommunity.com/sharedfiles/filedetails/?id=3782565181) 1.5.31** di **Kiidxatlas**. Abbiamo riletto tutto il codice confrontandolo con quello del gioco (Build 42.21) e corretto questo.

### Crash ed errori

- **Crash del bagliore del calore.** Quando un'arma non aveva il modello «caldo» per il silenziatore montato (succede con alcune combinazioni di arma e silenziatore e con armi cambiate da altre mod), il bagliore generava un errore ogni secondo; ogni errore scriveva nel log del gioco pagine intere, fino a farlo crollare. È la causa più probabile del crash segnalato con il silenziatore a filtro dell'olio da 9mm. Ora su quelle armi il silenziatore semplicemente non si illumina, senza nessun errore, e un'arma non resta mai incandescente per sbaglio.
- **Errore a ogni colpo.** Quando il gioco non permetteva di nascondere il lampo dello sparo, la mod chiamava una funzione che non esisteva e generava un errore a ogni colpo: probabilmente gli errori segnalati con le armi 5.56. Ora lo scrive una volta sola nel log.
- **Un errore non blocca più lo sparo.** Prima la mod rilanciava al gioco ogni suo errore: durante lo sparo poteva interrompere anche il codice che veniva dopo, e negli eventi che girano di continuo si ripeteva a ogni fotogramma. Ora viene scritto una volta nel log e quella parte della mod si ferma per 10 secondi: lo sparo resta normale.

### Silenziatori

- **In multiplayer i silenziatori di pompa, bolt e leva non si consumavano mai** (e non si scaldavano), e sulle altre armi l'ultimo colpo di ogni caricatore non contava. In single player invece un colpo poteva valere doppio, e contavano anche le spinte e il grilletto premuto a vuoto. Ora ogni colpo sparato conta una volta sola, ovunque, e il giocatore vede subito la condizione giusta, non quella del colpo prima.
- **Le righe del silenziatore nel tooltip** (durata, calore, compatibilità) comparivano solo a volte: ora sempre.
- **Smontare il silenziatore** accetta anche il multiutensile e il coltello a mano, come il resto del gioco. Senza un cacciavite la voce è grigia e dice perché, invece di annullare l'azione senza una parola.
- **La vampa dello sparo tornava** su un'arma silenziata dopo aver caricato un salvataggio.
- **Ricette di riparazione spiegate.** Le ricette «Ripara silenziatore tornito» (per esempio quella del .357) chiedono tra i materiali il silenziatore stesso, e sembrava un errore: è il silenziatore consumato che entra ed esce riparato. Ora la ricetta lo spiega.
- **Le ricette .30-30** date a chi aveva letto la vecchia versione del manuale ora compaiono subito, senza dover rientrare nel server.

### Olio e filtri dei veicoli

- **Un'auto poteva restare bloccata per sempre:** se il server si fermava mentre qualcuno smontava il filtro, da lì in poi nessuno poteva più smontarlo, rimontarlo o toccarne l'olio.
- **Lavori sull'olio rifiutati in silenzio:** se il server rifiutava un rabbocco o uno scarico (per esempio perché qualcuno aveva acceso il motore), non diceva niente e teneva l'auto occupata per 45 secondi; peggio, il lavoro dopo poteva eseguire quello vecchio (olio scaricato a terra invece che nella tanica). Ora ogni rifiuto viene detto e l'auto si libera subito.
- **Chi esce dal server** non lascia più l'auto occupata.
- **Motore distrutto in pochi minuti con l'olio spento:** con l'opzione dell'olio disattivata, guidare senza filtro distruggeva il motore in circa 25 minuti di gioco. Ora usa i valori lievi previsti.
- **Il client danneggiava il motore per conto suo** e mandava al server i dati dell'auto, magari vecchi, ogni minuto di gioco.
- **Un motore riparato** dopo essersi grippato ora può grippare di nuovo, se resta di nuovo a secco.

### Prestazioni del server

- **Memoria sprecata a ogni zona caricata:** il server lasciava un dato vuoto su ogni oggetto (muri, pavimenti, alberi) di ogni zona caricata dall'avvio. Ora no.
- **Controlli a ogni fotogramma:** l'inventario di ogni giocatore veniva scorso tutto, e le sue ricette ricontrollate, a ogni aggiornamento, per tutta la sessione. Ora una volta ogni 10 secondi, o una volta sola.
- **Armi tenute in memoria** per tutta la vita del server anche dopo essere sparite.

### Testi

- **Tutto in italiano**: oggetti, ricette, menu, messaggi, descrizioni e le impostazioni sandbox. Le descrizioni degli oggetti, che nell'originale erano scritte fisse in inglese, ora si possono tradurre.
- **L'opzione del calore** diceva che il calore non consuma il silenziatore: invece lo consuma di più, se l'apposita opzione è accesa (lo è di base). Ora il testo è giusto.

Ogni modifica nel codice è segnata con `[moon]`, così si ritrova facilmente. Non abbiamo cambiato le scelte di gioco dell'autore: per esempio le saldature della mod non consumano il gas della torcia al propano, esattamente come nell'originale.

## Crediti

- **Simple Suppressors**: Kiidxatlas ([Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3782565181)). Modelli, suoni, ricette e quasi tutto il codice sono suoi. Se la mod ti piace, lascia un pollice in su sulla sua pagina del Workshop.
- **Traduzione italiana e correzioni**: Moon, per il server RiversideMoon.
- **ZomBOT**: il bot Discord del server RiversideMoon.
