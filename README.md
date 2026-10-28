# Moon

Le mod per giocare a **Project Zomboid** (Build 42) sul server **Moon**, con un solo file da lanciare: **`mod-moon-server.bat`**.

**Per entrare sul server Moon non serve nessuna mod**: il server non ne chiede. Queste sono tutte facoltative, ognuna con la sua versione.

| Mod | Versione | Stato | A chi serve | Cos'è |
| --- | --- | --- | --- | --- |
| **ZomBOT** | 1.0.1 | Installabile | **a tutti** | Le domande a ZomBOT dalla chat del gioco, il contenitore che lampeggia dove c'è ciò che cerchi, le casse colorate. Vedi [ZomBOT: cosa fa](#zombot-cosa-fa). |
| **Admin-Scorte** | 1.1.1 | Installabile | **agli admin** del server | Le finestre di ZomBOT per gestire le basi e le loro scorte; a chi non è admin mostra solo dove un oggetto manca nelle basi. Vedi [Admin-Scorte: cosa fa](#admin-scorte-cosa-fa). |
| **Silenziatori** | 1.5.31-moon.1 | **Disattivata** | per ora a nessuno | I silenziatori per le armi: la mod Simple Suppressors di Kiidxatlas, tradotta in italiano e corretta. Per ora il pacchetto non la installa: vedi [Silenziatori (disattivata)](#silenziatori-disattivata). |

---

## Installazione (2 minuti)

1. **Scarica il pacchetto.** In questa pagina, in alto, premi il pulsante verde **`<> Code`** e poi **`Download ZIP`**.
2. **Estrai lo ZIP.** Tasto destro sul file scaricato, **«Estrai tutto...»**, poi **«Estrai»**. Non lanciare il file da dentro lo ZIP senza estrarlo: non troverebbe le mod da installare.
3. **Chiudi Project Zomboid**, se è aperto.
4. **Doppio clic su `mod-moon-server.bat`** nella cartella estratta.
   - Se compare la finestra blu **«Windows ha protetto il PC»**, premi **«Ulteriori informazioni»** e poi **«Esegui comunque»**; se invece compare **«Avviso di sicurezza»**, premi **«Esegui»**. Windows avvisa così per i file scaricati da internet che non hanno una firma: `mod-moon-server.bat` è testo semplice e chiunque può leggerlo prima (tasto destro, «Modifica»).
5. Si apre questo menu. Ti dice quali mod ci sono, con la loro versione, cosa hai già e dove ha trovato il gioco:

   ```
     ╔════════════════════════════════════════════════════════╗
     ║  MOON  ·  le mod per giocare sul server Moon           ║
     ╚════════════════════════════════════════════════════════╝
     Admin-Scorte 1.1.0  ·  ZomBOT 1.0.0  ·  Silenziatori disattivata

     Le mod di Moon

                         stato          versione        sul tuo computer
       Silenziatori      Disattivata    1.5.31-moon.1   non installata
       Admin-Scorte      Installabile   1.1.0           non installata · per gli admin
       ZomBOT            Installabile   1.0.0           non installata · per tutti

       Project Zomboid   C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid

     Cosa vuoi fare?

       [1]  Installa o aggiorna le mod per giocare      ZomBOT
       [2]  Installa o aggiorna tutto, anche da admin   ZomBOT + Admin-Scorte
       [3]  Scegli tu quali installare                  per esempio solo ZomBOT
       [4]  Disinstalla
       [0]  Esci

     Per entrare sul server Moon non serve nessuna mod: sono tutte facoltative.
   ```

   - Premi **`1`** se sei un giocatore: installa **ZomBOT**.
   - Premi **`2`** se sei admin del server: installa **ZomBOT** e **Admin-Scorte**.
   - Premi **`3`** per installare solo alcune mod, per esempio **solo Admin-Scorte**. Si apre una lista: premi il numero di una mod per sceglierla (compare **`[√]`**), premilo di nuovo per toglierla, poi **`I`** per installare quelle scelte. Silenziatori compare con **`[-]`**: è disattivata e non si può scegliere.

     ```
       Scegli cosa installare

         [1]  [-]  Silenziatori      1.5.31-moon.1   disattivata: per ora non si installa
         [2]  [√]  Admin-Scorte      1.1.0           vecchia
         [3]  [ ]  ZomBOT            1.0.0           aggiornata

         [I]  Installa le mod scelte
         [0]  Torna indietro
     ```

   Il file mostra ogni passo mentre lo fa: controlla che il gioco sia chiuso, copia i file e dice dove. Alla fine scrive **«Tutto pronto»** e ti ricorda come si usa ciò che hai installato. Premi un tasto per tornare al menu e **`0`** per uscire.
6. **Avvia Project Zomboid ed entra sul server Moon** come sempre. Non devi attivare niente nel menu Mod.

Il file trova da solo il gioco nelle librerie di Steam, anche su un altro disco. Se non ci riesce te lo dice: in quel caso **trascina la cartella `ProjectZomboid` sopra `mod-moon-server.bat`** (di solito è in `...\Steam\steamapps\common\ProjectZomboid`; da Steam: tasto destro sul gioco, «Gestisci», «Sfoglia i file locali»).

## Aggiornare

Ogni mod ha la sua versione (per ZomBOT e Admin-Scorte è scritta nel file `VERSION` della sua cartella) e il menu te la mostra. Nella colonna «sul tuo computer» dice **«aggiornata»** se hai proprio quella del pacchetto, **«vecchia»** se la tua è diversa, e quando la sa anche quale hai («vecchia · hai la 1.0.0»).

Quando esce una nuova versione: scarica di nuovo lo ZIP, estrailo, lancia `mod-moon-server.bat` e premi di nuovo **`1`** o **`2`**, oppure **`3`** per aggiornare solo una mod. Quella vecchia viene sostituita del tutto, non serve disinstallare prima.

## Disinstallare

Lancia `mod-moon-server.bat`, premi **`4`** e scegli:

- **`1`** toglie **Silenziatori**, se l'avevi installata prima che fosse disattivata;
- **`2`** toglie **Admin-Scorte**, per esempio se non sei più admin;
- **`3`** toglie **ZomBOT**;
- **`4`** toglie tutto.

Il file `ZomBotMenu.lua` lo usano sia Admin-Scorte sia ZomBOT (vedi sotto): se togli una delle due e l'altra c'è ancora, resta al suo posto; se le togli tutte e due, va via con l'ultima.

## Cosa installa, esattamente

| Mod | File | Dove |
| --- | --- | --- |
| ZomBOT | `ZomBotGioco.lua` | `<cartella del gioco>\media\lua\client\` |
| ZomBOT e Admin-Scorte | `ZomBotMenu.lua` (lo stesso file per tutte e due) | `<cartella del gioco>\media\lua\client\` |
| Admin-Scorte | `ZomBotStockUI.lua` | `<cartella del gioco>\media\lua\client\` |
| Admin-Scorte | `ZomBotData.lua` | `<cartella del gioco>\media\lua\shared\` |
| ZomBOT, Admin-Scorte | `Moon-ZomBOT.version`, `Moon-Admin-Scorte.version`: la versione installata, una riga | `<cartella del gioco>\media\lua\` |
| Silenziatori (disattivata) | la cartella `Silenziatori` | `C:\Users\<il tuo nome>\Zomboid\mods\` |

Non tocca nient'altro: i salvataggi, le impostazioni e le altre mod restano come sono.

**Il file in comune, `ZomBotMenu.lua`.** È l'unica voce **«ZomBOT»** del tasto destro: Admin-Scorte e ZomBOT ci aggiungono ciò che offrono, invece di avere ognuna le sue voci. Per questo è lo stesso file, identico, nelle cartelle `admin-scorte/client` e `zombot/client` del pacchetto, e si installa nello stesso posto: il gioco lo carica una volta sola, qualunque delle due mod tu abbia. Installare l'una o l'altra lo copia; toglierne una lo lascia finché c'è l'altra.

Perché Admin-Scorte e ZomBOT vanno nella cartella del gioco e non tra le mod? In multiplayer il gioco carica solo le mod che il server elenca, e se il server le elencasse tutti dovrebbero installarle per entrare. Così invece le installa solo chi le vuole, e il server (che accetta file in più dai giocatori) ricontrolla tutto ciò che chiedono: i file sul tuo computer non danno poteri a nessuno.

## Problemi frequenti

**«Non riesco a scrivere nella cartella del gioco».** Chiudi il gioco e riprova. Se non basta: tasto destro su `mod-moon-server.bat`, **«Esegui come amministratore»**.

**ZomBOT non risponde.** Controlla nel menu che ZomBOT sia **«aggiornata»** e che la riga in chat cominci proprio con «zombot». Si può chiedere una cosa ogni 10 secondi, e non più di 30 all'ora. Se il problema resta, scrivi nel canale del server su Discord.

**I colori del menu non si vedono e compaiono simboli strani.** Succede con le versioni di Windows più vecchie di Windows 10: il file funziona lo stesso.

**Ho un Mac o Linux.** `mod-moon-server.bat` funziona solo su Windows. A mano, dentro la cartella del gioco: per ZomBOT copia `zombot/client/ZomBotGioco.lua` e `zombot/client/ZomBotMenu.lua` in `media/lua/client/`; per Admin-Scorte copia `admin-scorte/client/ZomBotStockUI.lua` e `admin-scorte/client/ZomBotMenu.lua` in `media/lua/client/` e `admin-scorte/shared/ZomBotData.lua` in `media/lua/shared/`.

## ZomBOT: cosa fa

ZomBOT è il bot Discord del server. Con questa mod lo si usa anche **dentro il gioco**, e funziona per **tutti**, non solo per gli admin:

- **le domande dalla chat**: scrivi in chat una riga che comincia con **«zombot»** (anche «@ZomBOT», «zombot,» o «zombot:»), per esempio **«zombot dove trovo le asce?»**. La riga va in chat come sempre, compare «ZomBOT ci pensa...» e la risposta arriva nella tua chat: **la vedi solo tu**. Una domanda ogni 10 secondi, al massimo 30 all'ora;
- **dove sono le cose**: se sei dentro una base e chiedi dove trovare qualcosa, **il contenitore più vicino che lo contiene lampeggia** per te (anche se è dentro una borsa o una scatola). Smette quando ci clicchi sopra, quando lo apri, dopo un minuto o quando ne lampeggia un altro;
- **le casse colorate**: **tasto destro su una cassa → «ZomBOT: colora il contenitore»** e scegli uno degli 8 colori, o «Nessun colore». Il colore è lo stesso per tutto il server e lo vede chiunque abbia la mod; chi non ce l'ha vede le casse come sempre. Se non vuoi vederli, nella finestra di ZomBOT togli «Colora le casse»: vale solo per te;
- **la finestra di ZomBOT**: un clic su «ZomBOT» nel tasto destro. Spiega come chiedere, mostra le ultime risposte e l'interruttore dei colori.

Chi non ha la mod gioca come sempre e non vede niente di diverso. Il server ricontrolla ogni richiesta: la mod non dà poteri a nessuno.

## Admin-Scorte: cosa fa

ZomBOT conta le scorte delle basi (cibo, munizioni, medicine, libri...) e le mostra su Discord, per esempio con `/scorte` e `/basi`. Con Admin-Scorte gli admin decidono, dentro il gioco, quali basi ci sono e cosa tenere d'occhio. Nel tasto destro c'è **una sola voce, «ZomBOT»**:

- **tasto destro, ovunque, «ZomBOT»**: la finestra delle basi, con l'elenco e i pulsanti per crearle, modificarle (disegnandole sul terreno o sulla mappa, o prendendo la casa in cui sei), vederle sulla mappa e toglierle;
- **«Scorte...»**, nella finestra delle basi: le scorte di una base **per categoria**, ognuna da tracciare o no con un clic:
  - **Libri delle abilità**, con quante copie di ogni volume tenere;
  - **Riviste di ricette**, con quante copie di ognuna;
  - **VHS delle abilità**: ogni cassetta che insegna un'abilità c'è o manca;
  - **Provviste**: tutto il cibo insieme, contato in porzioni (circa un pasto l'una), senza numeri da scrivere.

  «Tutte le scorte...» elenca tutto ciò che la base tiene d'occhio, con le soglie e com'era all'ultimo conteggio;
- **tasto destro su un oggetto dentro una base → «ZomBOT» → «Aggiungi a scorta»**: tiene d'occhio quell'oggetto nella base, con le soglie «critico», «scarseggia» e «buono». Una confezione conta per ciò che contiene; un attrezzo si tiene d'occhio per lavoro («Seghe da legno» conta tutte le seghe che il gioco accetta per quel lavoro, senza quelle rotte); libri, riviste e VHS si tracciano solo per categoria, da «Scorte...»;
- **con anche ZomBOT installata**, nella finestra delle basi ci sono «Casse colorate» e le domande e risposte di ZomBOT.

**Chi non è admin e installa Admin-Scorte** non vede le finestre, ma ha **il riquadro delle scorte sotto gli oggetti**: passando il mouse su un oggetto, sotto il riquadro del gioco compare «ZomBOT - scorte» con le basi in cui quell'oggetto manca o scarseggia («Scarseggia a ... (300 su 1.000)», «Manca a ...» per un libro o una VHS). Il server rifiuta comunque ogni modifica che non arrivi da un admin.

## Silenziatori (disattivata)

**Per ora Silenziatori è disattivata**: il server non la usa, per entrare non serve e `mod-moon-server.bat` non la installa (nel menu compare «Disattivata»). Se l'avevi installata prima, il menu te lo dice e puoi toglierla con **`4`** e poi **`1`**.

Il codice resta nel pacchetto, nella cartella `mods/Silenziatori`, con le correzioni descritte sotto. Chi la vuole in una partita in single player può copiare a mano quella cartella in `C:\Users\<il tuo nome>\Zomboid\mods\`, poi dal menu principale: **Mod**, attiva **«Silenziatori»**, e crea una nuova partita (non insieme alla mod originale Simple Suppressors).

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
