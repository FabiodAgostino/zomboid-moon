# Moon

Le mod per giocare a **Project Zomboid** (Build 42) sul server **Moon**, con un solo file da lanciare: **`mod-moon-server.bat`**.

| Mod | A chi serve | Cos'è |
| --- | --- | --- |
| **Silenziatori** | **a tutti**: il server la usa, senza non si entra | I silenziatori per le armi: la mod Simple Suppressors di Kiidxatlas, tradotta in italiano e corretta (vedi [Cosa cambia rispetto all'originale](#cosa-cambia-rispetto-alloriginale)). |
| **Admin-Scorte** | **solo agli admin** del server | Le finestre di ZomBOT per gestire le basi e le loro scorte. Funzionano solo se sei admin sul server: per chiunque altro non mostrano niente e non danno nessun potere. |

---

## Installazione (2 minuti)

1. **Scarica il pacchetto.** In questa pagina, in alto, premi il pulsante verde **`<> Code`** e poi **`Download ZIP`**.
2. **Estrai lo ZIP.** Tasto destro sul file scaricato, **«Estrai tutto...»**, poi **«Estrai»**. Non lanciare il file da dentro lo ZIP senza estrarlo: non troverebbe le mod da installare.
3. **Chiudi Project Zomboid**, se è aperto.
4. **Doppio clic su `mod-moon-server.bat`** nella cartella estratta.
   - Se compare la finestra blu **«Windows ha protetto il PC»**, premi **«Ulteriori informazioni»** e poi **«Esegui comunque»**; se invece compare **«Avviso di sicurezza»**, premi **«Esegui»**. Windows avvisa così per i file scaricati da internet che non hanno una firma: `mod-moon-server.bat` è testo semplice e chiunque può leggerlo prima (tasto destro, «Modifica»).
5. Si apre questo menu. Ti dice cosa hai già e dove ha trovato il gioco:

   ```
     ╔════════════════════════════════════════════════════════╗
     ║  MOON  ·  le mod per giocare sul server Moon           ║
     ╚════════════════════════════════════════════════════════╝
     Silenziatori 1.5.31-moon.1  ·  Admin-Scorte

     Sul tuo computer

       Silenziatori      non installata
       Admin-Scorte      non installata, serve solo agli admin
       Project Zomboid   C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid

     Cosa vuoi fare?

       [1]  Installa o aggiorna le mod per giocare      Silenziatori
       [2]  Installa o aggiorna tutto, anche da admin   Silenziatori + Admin-Scorte
       [3]  Scegli tu quali installare                  per esempio solo Admin-Scorte
       [4]  Disinstalla
       [0]  Esci
   ```

   - Premi **`1`** se sei un giocatore: installa **Silenziatori**.
   - Premi **`2`** se sei admin del server: installa **Silenziatori** e **Admin-Scorte**.
   - Premi **`3`** per installare solo alcune mod, per esempio **solo Admin-Scorte** se Silenziatori ce l'hai già. Si apre una lista: premi il numero di una mod per sceglierla (compare **`[√]`**), premilo di nuovo per toglierla, poi **`I`** per installare quelle scelte.

     ```
       Scegli cosa installare

         [1]  [ ]  Silenziatori      installata versione 1.5.31-moon.1
         [2]  [√]  Admin-Scorte      da aggiornare

         [I]  Installa le mod scelte
         [0]  Torna indietro
     ```

   Il file mostra ogni passo mentre lo fa: controlla che il gioco sia chiuso, prepara la cartella delle mod, copia i file e dice dove. Alla fine scrive **«Tutto pronto»**. Premi un tasto per tornare al menu e **`0`** per uscire.
6. **Avvia Project Zomboid ed entra sul server Moon** come sempre. Non devi attivare niente nel menu Mod: in multiplayer le mod le attiva il server.

Il file trova da solo il gioco nelle librerie di Steam, anche su un altro disco. Se non ci riesce te lo dice: in quel caso **trascina la cartella `ProjectZomboid` sopra `mod-moon-server.bat`** (di solito è in `...\Steam\steamapps\common\ProjectZomboid`; da Steam: tasto destro sul gioco, «Gestisci», «Sfoglia i file locali»).

## Aggiornare

Quando esce una nuova versione: scarica di nuovo lo ZIP, estrailo, lancia `mod-moon-server.bat` e premi di nuovo **`1`** o **`2`**, oppure **`3`** per aggiornare solo una mod. Il menu ti dice se hai una versione vecchia («da aggiornare»); quella vecchia viene sostituita del tutto, non serve disinstallare prima.

## Disinstallare

Lancia `mod-moon-server.bat`, premi **`4`** e scegli:

- **`1`** toglie solo **Admin-Scorte**, per esempio se non sei più admin;
- **`2`** toglie tutto: **Silenziatori** e **Admin-Scorte**. Senza Silenziatori non puoi entrare sul server Moon.

## Cosa installa, esattamente

| Mod | File | Dove |
| --- | --- | --- |
| Silenziatori | la cartella `Silenziatori` | `C:\Users\<il tuo nome>\Zomboid\mods\` |
| Admin-Scorte | `ZomBotData.lua` | `<cartella del gioco>\media\lua\shared\` |
| Admin-Scorte | `ZomBotStockUI.lua` | `<cartella del gioco>\media\lua\client\` |

Non tocca nient'altro: i salvataggi, le impostazioni e le altre mod restano come sono.

Perché Admin-Scorte va nella cartella del gioco e non tra le mod? In multiplayer il gioco carica solo le mod che il server elenca, e se il server elencasse Admin-Scorte tutti dovrebbero installarla per entrare. Così invece la installa solo chi la vuole, e il server (che accetta file in più dai giocatori) la lascia funzionare solo per gli admin.

## Problemi frequenti

**«Non riesco a scrivere nella cartella del gioco».** Chiudi il gioco e riprova. Se non basta: tasto destro su `mod-moon-server.bat`, **«Esegui come amministratore»**.

**Entrando nel server il gioco dice che manca una mod, o che le mod non corrispondono.** Rilancia `mod-moon-server.bat` e premi `1`: probabilmente sul server c'è una versione più nuova. Se il problema resta, scrivi nel canale del server su Discord.

**I colori del menu non si vedono e compaiono simboli strani.** Succede con le versioni di Windows più vecchie di Windows 10: il file funziona lo stesso.

**Ero iscritto alla mod originale Simple Suppressors sul Workshop.** Puoi lasciarla: sul server si usa Silenziatori. In una partita in single player però non attivarle tutte e due insieme.

**Voglio usare i silenziatori anche in single player.** Dal menu principale: **Mod**, attiva **«Silenziatori»**, poi crea una nuova partita.

**Ho un Mac o Linux.** `mod-moon-server.bat` funziona solo su Windows. A mano: copia la cartella `mods/Silenziatori` in `~/Zomboid/mods/`. Admin-Scorte serve solo agli admin: copia `admin-scorte/shared/ZomBotData.lua` e `admin-scorte/client/ZomBotStockUI.lua` in `media/lua/shared/` e `media/lua/client/` dentro la cartella del gioco.

## Admin-Scorte: cosa fa

ZomBOT è il bot Discord del server. Conta le scorte delle basi (cibo, munizioni, medicine, libri...) e le mostra su Discord, per esempio con `/scorte` e `/basi`. Con Admin-Scorte gli admin decidono, dentro il gioco, quali basi ci sono e cosa tenere d'occhio:

- **tasto destro sul pavimento, «ZomBOT: basi...»**: crea, modifica o elimina le basi, disegnandole sulla mappa;
- **tasto destro sul pavimento dentro una base, «ZomBOT: scorte di questa base»**: le scorte tracciate, con la possibilità di smettere di tracciarne una;
- **tasto destro su un oggetto, «Aggiungi a scorta»**: tiene d'occhio quell'oggetto nella base, con le soglie «critico», «scarseggia» e «buono»;
- **un attrezzo si tiene d'occhio per lavoro**: «Aggiungi a scorta: Seghe da legno» conta tutti gli attrezzi che il gioco accetta per quel lavoro (Sega, Sega da giardino, Sega per legno semplice), senza quelli rotti. Un attrezzo che fa più lavori offre «Scorta degli attrezzi» con ognuno;
- **«Controlla i libri» / «Controlla le riviste»**: quali libri delle abilità e quali riviste di ricette mancano nella base;
- **«Controlla le VHS»**: quali delle 62 VHS che insegnano un'abilità (guardarle dà esperienza) ci sono e quali mancano nella base, tutte o quelle di un'abilità, come i libri. Ogni cassetta c'è o manca: niente copie da scegliere.

Funziona solo per gli admin: per chi non lo è i menu non compaiono, e il server rifiuta comunque ogni modifica che non arrivi da un admin.

## Cosa cambia rispetto all'originale

**Silenziatori** nasce da **[Simple Suppressors](https://steamcommunity.com/sharedfiles/filedetails/?id=3782565181) 1.5.31** di **Kiidxatlas**. Abbiamo riletto tutto il codice confrontandolo con quello del gioco (Build 42.21) e corretto questo.

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

- **Simple Suppressors**, da cui nasce Silenziatori: Kiidxatlas ([Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3782565181)). Modelli, suoni, ricette e quasi tutto il codice sono suoi. Se la mod ti piace, lascia un pollice in su sulla sua pagina del Workshop.
- **Traduzione italiana e correzioni**: per il server Moon.
- **ZomBOT e Admin-Scorte**: il bot Discord del server Moon.
