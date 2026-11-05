# Moon

Le mod per giocare a **Project Zomboid** (Build 42) sul server **Moon**.

**Per giocare su Moon serve una mod: «ZomBOT (Moon)»**, cioè ZomBOT e Admin-Scorte insieme. La installa e la aggiorna da solo il **[launcher di Moon](#il-launcher-moonlauncherexe)**; in alternativa c'è [`mod-moon-server.bat`](#in-alternativa-mod-moon-serverbat). Sugli altri server non si carica.

| Mod | Stato | Come arriva | Cos'è |
| --- | --- | --- | --- |
| **ZomBOT (Moon)** | **Obbligatoria** | il launcher la installa e la aggiorna da solo, in `%UserProfile%\Zomboid\mods\ZomBOTMoon`; sugli altri server non si carica | ZomBOT e Admin-Scorte insieme: le domande a ZomBOT dalla chat del gioco, il contenitore che lampeggia, le casse colorate e, per gli admin, le finestre delle basi e delle scorte. Vedi [ZomBOT: cosa fa](#zombot-cosa-fa) e [Admin-Scorte: cosa fa](#admin-scorte-cosa-fa). |
| **Silenziatori** | **Disattivata** | per ora a nessuno | I silenziatori per le armi: la mod Simple Suppressors di Kiidxatlas, tradotta in italiano e corretta. Vedi [Silenziatori (disattivata)](#silenziatori-disattivata). |
| **SilencerMoon** | **In prova** (disattivata) | per ora a nessuno | I silenziatori artigianali che prenderanno il posto di Silenziatori: leghe fuse da un fucile a pompa, silenziatori per pistole e per fucili, il filtro dell'olio come ripiego. Vedi [SilencerMoon (in prova)](#silencermoon-in-prova). |

---

## ZomBOT e Admin-Scorte ora sono ZomBOT (Moon)

Prima ZomBOT e Admin-Scorte erano file copiati nella cartella del gioco, in `media\lua`. Il gioco li carica **su qualsiasi server**, e un server che controlla i file Lua (l'opzione DoLuaChecksum, accesa di base) **espelle chi li ha**: «your game files do not match the server's». Ora sono una mod vera, **ZomBOT (Moon)**, nella cartella delle mod: si carica solo sui server che la vogliono, come Moon.

**Se li avevi installati, quei vecchi file vanno tolti.** Lo fanno da soli:

- **il launcher**, dalla versione 1.0.2: all'avvio li trova e li toglie, e ti dice quali. Se il gioco è aperto, aspetta che lo chiudi;
- **`mod-moon-server.bat`**: con **`1`** installa ZomBOT (Moon) e li toglie.

Tolgono solo questi file, e niente altro:

| File | Dove |
| --- | --- |
| `ZomBotGioco.lua`, `ZomBotMenu.lua`, `ZomBotStockUI.lua`, `ZomBotGravesUI.lua` | `<cartella del gioco>\media\lua\client\` |
| `ZomBotData.lua` | `<cartella del gioco>\media\lua\shared\` |
| `Moon-ZomBOT.version`, `Moon-Admin-Scorte.version` | `<cartella del gioco>\media\lua\` |

Puoi anche toglierli a mano. La cartella del gioco di solito è `...\Steam\steamapps\common\ProjectZomboid`; da Steam: tasto destro sul gioco, «Gestisci», «Sfoglia i file locali».

## Il launcher: MoonLauncher.exe

Il modo più semplice è il launcher di Moon: un solo file, da scaricare dalle **[Release](https://github.com/FabiodAgostino/zomboid-moon/releases/latest)**. Nella pagina, sotto «Assets», **scarica `MoonLauncher.exe`, non «Source code»**: quelli sono i sorgenti del repo, che GitHub aggiunge a ogni release.

Lo apri con un doppio clic: non si installa niente. Ti mostra le mod di Moon e com'è il tuo computer, installa ZomBOT (Moon) e toglie i vecchi file di ZomBOT. Con **GIOCA** controlla che ZomBOT (Moon) sia quella giusta, se serve la aggiorna, e avvia Project Zomboid. Si aggiorna da solo quando esce una versione nuova. Se compare la finestra blu **«Windows ha protetto il PC»**, premi **«Ulteriori informazioni»** e poi **«Esegui comunque»**: Windows avvisa così per i programmi scaricati che non hanno una firma.

Cosa fa e come si pubblica una versione: [launcher/README.md](launcher/README.md).

## In alternativa: mod-moon-server.bat

1. **Scarica il pacchetto.** In questa pagina, in alto, premi il pulsante verde **`<> Code`** e poi **`Download ZIP`**.
2. **Estrai lo ZIP.** Tasto destro sul file scaricato, **«Estrai tutto...»**, poi **«Estrai»**.
3. **Doppio clic su `mod-moon-server.bat`** nella cartella estratta. Se compare **«Windows ha protetto il PC»**, premi **«Ulteriori informazioni»** e poi **«Esegui comunque»**; se compare **«Avviso di sicurezza»**, premi **«Esegui»**. È testo semplice e chiunque può leggerlo prima (tasto destro, «Modifica»).
4. Si apre questo menu:

   ```
     ╔════════════════════════════════════════════════════════╗
     ║  MOON  ·  le mod per giocare sul server Moon           ║
     ╚════════════════════════════════════════════════════════╝
     ZomBOT (Moon) 2.0.0  ·  SilencerMoon in prova

     Le mod di Moon

                         stato          versione        sul tuo computer
       ZomBOT (Moon)     Obbligatoria   2.0.0           non installata · senza non entri su Moon: premi 1
       SilencerMoon      In prova       0.1.0           non installata

       Project Zomboid   C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid

     Nella cartella del gioco ci sono ancora 7 vecchi file di ZomBOT e Admin-Scorte:
     sugli altri server ti fanno espellere. Premi 1: li tolgo e installo ZomBOT (Moon).

     Cosa vuoi fare?

       [1]  Installa o aggiorna ZomBOT (Moon)   2.0.0, e tolgo 7 vecchi file
       [2]  Installa o aggiorna SilencerMoon    in prova: per ora non si installa
       [3]  Togli SilencerMoon e Silenziatori
       [0]  Esci
   ```

   - **`1`** installa o aggiorna ZomBOT (Moon), dopo aver controllato che il gioco sia chiuso. Se nella cartella del gioco ci sono ancora i vecchi file di ZomBOT e Admin-Scorte, li toglie e dice quali. Quando esce una versione nuova, riscarica lo ZIP e premi di nuovo `1`;
   - **`2`** installa o aggiorna SilencerMoon, quando non sarà più in prova;
   - **`3`** toglie SilencerMoon e la vecchia Silenziatori, se le avevi installate. Silenziatori non si installa più: nel menu compare solo a chi ce l'ha ancora, come «Sostituita», per toglierla.

Il file trova da solo il gioco nelle librerie di Steam, anche su un altro disco. Se non ci riesce te lo dice: in quel caso **trascina la cartella `ProjectZomboid` sopra `mod-moon-server.bat`**.

## Problemi frequenti

**Entrando su Moon il gioco dice che manca una mod, o che è diversa da quella del server.** È ZomBOT (Moon), che manca o è vecchia: apri il launcher e premi GIOCA, la installa o la aggiorna e poi avvia il gioco. Con il bat, riscarica lo ZIP e premi `1`.

**Un altro server mi espelle: «your game files do not match the server's».** Nella cartella del gioco ci sono ancora i vecchi file di ZomBOT o di Admin-Scorte: apri il launcher, oppure `mod-moon-server.bat` e premi `1`, oppure toglili a mano (vedi [la tabella sopra](#zombot-e-admin-scorte-ora-sono-zombot-moon)).

**«Non riesco a togliere i file dalla cartella del gioco».** Chiudi il gioco e riprova. Se non basta: con il launcher premi «Riavvia come amministratore»; con il bat, tasto destro su `mod-moon-server.bat`, **«Esegui come amministratore»**.

**ZomBOT non risponde.** Controlla che la riga in chat cominci proprio con «zombot». Si può chiedere una cosa ogni 10 secondi, e non più di 30 all'ora. Se il problema resta, scrivi nel canale del server su Discord.

**I colori del menu di `mod-moon-server.bat` non si vedono e compaiono simboli strani.** Succede con le versioni di Windows più vecchie di Windows 10: il file funziona lo stesso.

**Ho un Mac o Linux.** Il launcher e `mod-moon-server.bat` funzionano solo su Windows. Copia a mano la cartella `mods/ZomBOTMoon` del repo dentro `~/Zomboid/mods/`, e ricopiala quando esce una versione nuova. Se avevi copiato a mano i vecchi file di ZomBOT e Admin-Scorte, toglili dalla cartella del gioco (sono quelli della [tabella sopra](#zombot-e-admin-scorte-ora-sono-zombot-moon)).

## ZomBOT: cosa fa

ZomBOT è il bot Discord del server. Con questa mod lo si usa anche **dentro il gioco**, e funziona per **tutti**, non solo per gli admin:

- **le domande dalla chat**: scrivi in chat una riga che comincia con **«zombot»** (anche «@ZomBOT», «zombot,» o «zombot:»), per esempio **«zombot dove trovo le asce?»**. La riga va in chat come sempre, compare «ZomBOT ci pensa...» e la risposta arriva nella tua chat: **la vedi solo tu**. Una domanda ogni 10 secondi, al massimo 30 all'ora;
- **dove sono le cose**: se sei dentro una base e chiedi dove trovare qualcosa, **il contenitore più vicino che lo contiene lampeggia** per te (anche se è dentro una borsa o una scatola). Smette quando ci clicchi sopra, quando lo apri, dopo un minuto o quando ne lampeggia un altro;
- **le casse colorate**: **tasto destro su una cassa → «ZomBOT: colora il contenitore»** e scegli uno degli 8 colori, o «Nessun colore». Il colore è lo stesso per tutto il server e lo vede chiunque abbia la mod; chi non ce l'ha vede le casse come sempre. Se non vuoi vederli, nella finestra di ZomBOT togli «Colora le casse»: vale solo per te;
- **la finestra di ZomBOT**: un clic su «ZomBOT» nel tasto destro. Spiega come chiedere, mostra le ultime risposte e l'interruttore dei colori.

Il server ricontrolla ogni richiesta: la mod non dà poteri a nessuno.

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
- nella finestra delle basi ci sono anche «Casse colorate» e le domande e risposte di ZomBOT.

**Chi non è admin** non vede le finestre, ma ha **il riquadro delle scorte sotto gli oggetti**: passando il mouse su un oggetto, sotto il riquadro del gioco compare «ZomBOT - scorte» con le basi in cui quell'oggetto manca o scarseggia («Scarseggia a ... (300 su 1.000)», «Manca a ...» per un libro o una VHS). Il server rifiuta comunque ogni modifica che non arrivi da un admin.

## SilencerMoon (in prova)

**SilencerMoon** è la mod dei silenziatori artigianali di Moon, rifatta da capo partendo da Simple Suppressors: prenderà il posto di Silenziatori. **Per ora è in prova**: il launcher non la installa e il server non la usa. Nessun silenziatore si trova già fatto: si costruiscono tutti.

| Silenziatore | Come si ottiene | Rumore | Gittata di base | Danno | Durata media |
| --- | --- | ---: | ---: | ---: | ---: |
| **A filtro dell'olio** | un filtro smontato da un veicolo (Meccanica 8, chiave inglese, una volta per veicolo) + dadi e bulloni, Saldatura 3 | -65% | -40% | -25% | 25 spari |
| **Acciaio Ramato** | 3 lingotti (pistole) o 4 (fucili) di Acciaio Ramato, Saldatura 7 | -80% | -30% | -20% | 100 spari |
| **Lega Balistica** | 3 o 4 lingotti di Lega Balistica di Recupero, Saldatura 7 | -90% | -20% | -12,5% | 1.000 spari |

- **Le leghe** si fondono alla fornace (fornace di fusione o altoforno) con Forgiatura 5: un fucile a pompa (anche rotto, purché scarico e senza accessori), più 2 scarti di rame e una lamiera piccola per l'Acciaio Ramato, o 2 tubi di metallo e 2 lamiere piccole per la Lega Balistica. Servono crogiolo, pinze e stampo per lingotti, e 8 di carbone. Escono 4 lingotti.
- **I silenziatori** si saldano con torcia al propano (ne consumano il gas), bacchette per saldatura, maschera, trapano e lima. Le ricette si imparano da una **rivista** piuttosto rara, che si trova nelle armerie, nelle librerie, nelle ferramenta e nelle officine.
- **Armi:** per le pistole la Pistola, la Pistola M1911 e la Pistola D-E; per i fucili il Fucile d'assalto M16, il Fucile Varmint, il Fucile JS-14, il Fucile M14, il Fucile da caccia, il Fucile tattico MSR7T, il Fucile L94 e anche la Carabina da cacciatore e la Carabina L92 (munizioni da pistola, ma armi da spalla). Niente fucili a pompa né revolver. Il silenziatore a filtro dell'olio va su tutte.
- **Si monta** con «Migliora» e **si smonta** con «Rimuovi miglioramento» (il tasto destro sull'arma), senza attrezzi. Il rumore è la distanza da cui gli zombie sentono lo sparo (un Fucile da caccia passa da 170 caselle a 17 con la Lega Balistica, a 34 con l'Acciaio Ramato, a 59 con il filtro; una Pistola da 100 a 10, 20 e 35; al chiuso il gioco le dimezza); gittata e danno calano finché il silenziatore è montato e funziona. La gittata che cala è quella di base dell'arma: il bonus della Mira si aggiunge intero, quindi chi ha molta Mira perde meno. Il suono silenziato lo sentono anche gli altri giocatori, e anche loro non vedono la fiammata; resta solo la breve luce che il gioco accende a ogni sparo di un'arma da fuoco, che una mod non può togliere. Si consuma sparando, a caso: quando si rompe compare sopra la testa «Silenziatore rotto», resta montato ma non fa più niente, e il riquadro dell'oggetto dice che è rotto; smontato, torna nell'inventario come gli altri. Finché funziona, le barre nel riquadro mostrano i tre valori.
- **Per gli admin**, nel menu «ZomBOT» del tasto destro, il pulsante **«Silenziatori»** apre una finestra con i valori dei tre silenziatori (fissi nella mod) e il ripristino per togliere la mod (sotto). Con ZomBOT (Moon) il pulsante è nella finestra principale di ZomBOT; senza, «ZomBOT» apre direttamente quella dei silenziatori.

### Togliere SilencerMoon dal server

**Prima di togliere la mod dal server, un admin deve togliere i silenziatori da tutte le armi.** Un'arma salva la sua gittata e il suo danno, quindi resterebbe penalizzata per sempre; e un'arma con montato un pezzo che non esiste più **sparisce** quando il gioco la ricarica (verificato nel codice del gioco 42.21). Per questo:

1. un admin, nel gioco: **tasto destro → «ZomBOT» → «Silenziatori» → «Accendi il ripristino»** (chiede conferma). Da quel momento nessuno può montarne uno e il server toglie il silenziatore da ogni arma che raggiunge, ridandole gittata e danno; il silenziatore resta accanto all'arma. Subito: le armi dei giocatori collegati e quelle nei veicoli caricati. Poi ogni dieci minuti di gioco, anche con chi entra dopo, e con contenitori, oggetti a terra e cadaveri appena la loro zona si carica. Sopra la testa dell'admin compare quante armi ha sistemato, e la finestra dice quante ne ha sistemate finora («Aggiorna» lo richiede al server). Resta acceso anche dopo un riavvio del server. Chi spara con un silenziatore montato mentre è acceso viene sistemato a quel colpo;
2. **riavvia il server**: le zone già caricate quando l'hai acceso (per esempio la base dove c'è sempre qualcuno) vengono ricontrollate solo quando si ricaricano;
3. lascialo acceso **finché tutti i giocatori sono entrati almeno una volta e le basi e i posti dove ci sono armi sono stati visitati**: quello che nessuno carica non viene raggiunto;
4. togli la mod dal server; i giocatori la tolgono con il launcher o con `3` di `mod-moon-server.bat`.

Se ci ripensi, nella stessa finestra **«Spegni il ripristino»**: i silenziatori tolti si rimontano a mano.

Le armi sistemate nei veicoli vengono rimandate a chi è lì vicino, così anche sul suo schermo il silenziatore è staccato e accanto all'arma.

Il progetto completo, con le scelte e le verifiche fatte sui file del gioco 42.21, è nell'analisi v1.2 (non in questo repository). Le prove del Lua: `python -m pytest -q tests/silencermoon` con un Python che ha `pytest` e `lupa` (per esempio quello di ZomBOT). Gli script in `tools/silencermoon` rifanno le icone ramate, la texture e il poster.

## Silenziatori (disattivata)

**Silenziatori è disattivata e sarà sostituita da SilencerMoon**: il server non la usa, per entrare non serve, e il launcher e `mod-moon-server.bat` non la installano. Se l'avevi installata prima te lo dicono: nel launcher premi **TOGLI** nella sua scheda, nel bat **`3`**.

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

- **SilencerMoon** riusa modelli 3D, icone e allineamenti alle armi di Simple Suppressors; i suoni silenziati sono registrazioni CC0 (vedi `SOURCES.txt` nella mod).
- **Simple Suppressors**, da cui nasce Silenziatori: Kiidxatlas ([Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3782565181)). Modelli, suoni, ricette e quasi tutto il codice sono suoi. Se la mod ti piace, lascia un pollice in su sulla sua pagina del Workshop.
- **Traduzione italiana e correzioni**: per il server Moon.
- **ZomBOT e Admin-Scorte**: il bot Discord del server Moon.
