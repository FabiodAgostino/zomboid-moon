# Il launcher di Moon

`MoonLauncher.exe` è il programma che installa, aggiorna e toglie le mod del server **Moon** e avvia Project Zomboid. Fa quello che faceva `mod-moon-server.bat`, più gli aggiornamenti: chi lo scarica una volta dalle [Release](https://github.com/FabiodAgostino/zomboid-moon/releases) non deve più scaricare ZIP.

È un solo file `.exe` (WPF, .NET 10, con il runtime dentro): non si installa niente, si apre e basta.

## Cosa fa

- **Mod come schede con un interruttore.** Accendi e la mod si installa; spegni e si toglie, dopo una domanda. Le altre sono facoltative; una mod con `"required": true` invece serve per entrare sul server (oggi ZomBOT (Moon)) e dalla 1.0.2 ha una scheda senza interruttore, con «SERVE PER MOON»: **il launcher la installa da solo all'avvio se manca**, e **GIOCA la aggiorna prima di avviare** se non è identica a quella della release, senza chiedere. Per lei non c'è la scelta della versione: deve essere quella del server.
- **Aggiornamenti.** All'avvio legge l'ultima release del repo e scarica il suo `moon-mods.zip` (una sola volta per release). Confronta ogni file installato con quello della release, byte per byte, come faceva il bat con `fc /b`. Se qualcosa è diverso la mod diventa **Da aggiornare**, e GIOCA diventa **AGGIORNA**.
- **Versione a scelta.** Accanto al nome di ogni mod c'è la sua versione: con più versioni pubblicate si apre un menu con tutte, la più nuova in cima. Una versione precedente si installa dalla release che l'aveva pubblicata; la scheda dice «versione scelta da te», e il launcher non la aggiorna da solo finché non si sceglie di nuovo l'ultima.
- **Stato: «Installabile» o «Disattivata».** Lo decide il repo (vedi [Disattivare una mod](#disattivare-o-riattivare-una-mod)). Una mod disattivata non si installa né si aggiorna. Se qualcuno ce l'ha già, il launcher lo avvisa e nella scheda offre **TOGLI**, ma non la toglie da solo: tenerla installata non fa niente di male, il gioco carica solo quello che il server chiede.
- **Le installazioni del bat.** Riconosce le mod installate con `mod-moon-server.bat` (dai file, e dalla versione scritta in `media\lua\Moon-<mod>.version`), e scrive quei file come il bat: si può passare dall'uno all'altro.
- **In home**, come il bat, una tabella con ogni mod, la sua versione e com'è sul computer: aggiornata, da aggiornare, non installata, disattivata.
- **Le mod che una mod sostituisce** (dalla 1.0.2). ZomBOT (Moon) contiene ZomBOT e Admin-Scorte, che prima si copiavano nella cartella del gioco: le loro schede non si vedono più, e **all'avvio il launcher toglie dalla cartella del gioco i loro vecchi file**, solo quelli che `mods.json` elenca, e dice quali. Il gioco li caricherebbe su qualsiasi server, e chi controlla i file Lua espelle chi li ha. Se il gioco è aperto aspetta che si chiuda; se non conosce la cartella del gioco non fa niente.
- **File condivisi.** Un file che due mod mettono nello stesso posto (`ZomBotMenu.lua`, in Admin-Scorte e in ZomBOT) resta finché è installata almeno una delle due.
- **GIOCA** avvia il gioco con `steam://rungameid/108600`; senza Steam, con `ProjectZomboid64.exe`. Se prima c'è da installare o aggiornare (INSTALLA, AGGIORNA), lo fa e poi avvia il gioco. **Quando il gioco parte, il launcher si chiude.** Se l'avvio non riesce resta aperto e dice perché. Con il gioco già aperto le mod non si toccano: se serve, il launcher aspetta che si chiuda.
- **Il gioco** lo trova come il bat: nella cartella data al launcher (trascinata sulla finestra o sull'exe, oppure scelta con «Cambia cartella»), poi nella cartella di Steam e in tutte le librerie di `libraryfolders.vdf`.
- **Notizie**: sono le note delle release di GitHub, scritte in markdown.
- **Si aggiorna da solo.** Se il campo `launcher` di `mods.json` nell'ultima release è più alto della versione dell'exe, compare **AGGIORNA E RIAVVIA**. Il launcher scarica il nuovo exe, ne controlla lo SHA-256, prende il posto del vecchio e si riavvia.
- Senza connessione usa le mod e le notizie scaricate l'ultima volta.

Dove tiene le sue cose: `%LocalAppData%\Moon` (`installate.json` con le mod e le versioni installate, `impostazioni.json` con la cartella del gioco, `cache` con l'ultima release scaricata).

## mods.json: aggiungere o cambiare una mod

Le mod non sono scritte nel launcher: sono in [`mods.json`](../mods.json), in cima al repo. Per una mod nuova basta aggiungere una voce e pubblicare una release.

```json
{
  "id": "zombot",
  "name": "ZomBOT",
  "versionFile": "zombot/VERSION",
  "state": "installabile",
  "audience": "Per tutti",
  "summary": "Una riga che dice cos'è.",
  "note": "Una riga in più, per esempio a chi serve.",
  "afterInstall": "Cosa dire dopo l'installazione.",
  "installedVersion": { "file": "{game}/media/lua/Moon-ZomBOT.version" },
  "install": [
    { "from": "zombot/client", "to": "{game}/media/lua/client" }
  ]
}
```

| Campo | Cosa fa |
| --- | --- |
| `id` | Unico, non cambiarlo più: il launcher ricorda così cosa ha installato. |
| `name` | Come compare nella scheda. |
| `versionFile`, `versionKey` | Il file della mod con la sua versione: la prima riga (`VERSION`), o il valore di `versionKey` (per Silenziatori `modversion` in `mod.info`). In alternativa si scrive la versione direttamente, `"version": "1.0.0"`. Quando cambi i file di una mod, alza la sua versione. |
| `state`, `stateNote` | `"installabile"` (se manca è così) o `"disattivata"`, con il motivo facoltativo che compare nella scheda. |
| `required` | `true` se senza questa mod non si entra sul server. |
| `audience`, `summary`, `note`, `afterInstall` | I testi della scheda e dell'avviso dopo l'installazione. Facoltativi. |
| `image` | Un'immagine del repo per la scheda. Facoltativa: senza, c'è l'iniziale del nome. |
| `installedVersion` | Dove sta la versione installata. Con `"key"` è una riga di un file della mod (`modversion` di `mod.info`); senza, è un file di una riga che il launcher scrive accanto alla mod e toglie con lei, come il bat (`Moon-ZomBOT.version`). Facoltativo. |
| `install` | Cosa copiare. `from` è un file o una cartella del repo (una cartella porta tutti i suoi file, anche nelle sottocartelle). `to` comincia con `{zomboid}` (`%UserProfile%\Zomboid`) o `{game}` (la cartella del gioco). |
| `mirror` | `true` rende la cartella di destinazione identica alla mod, come `robocopy /MIR`: i file in più vengono cancellati. Si può solo per una cartella propria dentro `{zomboid}`, per esempio `{zomboid}/mods/Silenziatori`. |

Due mod possono mettere lo stesso file nello stesso posto solo se i due file sono identici: il pacchetto della release lo controlla e si ferma se non è così.

### File che non stanno nel repo: `pack` (dalla 1.0.3)

Jukebox (Moon) ha il motore nel repo e il catalogo dei CD fuori: lo fa `tools/jukebox` e lo pubblica come allegati della pre-release `jukebox` del repo (il launcher non prende mai una pre-release per una sua versione).

```json
"pack": { "release": "jukebox", "to": "{zomboid}/mods/JukeboxMoon", "keyFile": "{zomboid}/Lua/JukeboxMoon_key.txt" }
```

| Campo di `pack` | Cosa fa |
| --- | --- |
| `release` | Il tag della pre-release con `manifest.json`, `catalog-*.zip` e gli album `a*-*.jbm`. |
| `to` | Dove vanno i file: la cartella della mod, quella del suo `install` con `mirror`. |
| `keyFile` | Dove il gioco scrive la chiave della musica quando il giocatore entra sul server. |

I file del pacchetto entrano nel piano della mod come quelli del repo: lo stesso confronto, e il `mirror` non li toglie. Il catalogo pubblico va a tutti; gli album, cifrati, solo con la chiave giusta. Si scarica solo ciò che manca o è cambiato, e ogni file si verifica prima di installarlo (`Core/Pack.cs`). Le impronte dei file installati si ricordano (`hashes.json` nella cache): la musica non si rilegge a ogni avvio.

### Una mod che ne sostituisce altre: `replaces`

ZomBOT (Moon) è ZomBOT e Admin-Scorte insieme, in una mod vera dentro `{zomboid}/mods`. La sua voce dice quali mod prende il posto e quali vecchi file togliere:

```json
{
  "id": "zombot-moon",
  "name": "ZomBOT (Moon)",
  "versionFile": "mods/ZomBOTMoon/42/mod.info",
  "versionKey": "modversion",
  "state": "installabile",
  "required": true,
  "installedVersion": { "file": "{zomboid}/mods/ZomBOTMoon/42/mod.info", "key": "modversion" },
  "install": [
    { "from": "mods/ZomBOTMoon", "to": "{zomboid}/mods/ZomBOTMoon", "mirror": true }
  ],
  "replaces": {
    "mods": ["zombot", "admin-scorte"],
    "what": "ZomBOT e Admin-Scorte",
    "files": [
      "{game}/media/lua/client/ZomBotGioco.lua",
      "{game}/media/lua/Moon-ZomBOT.version"
    ]
  }
}
```

| Campo di `replaces` | Cosa fa |
| --- | --- |
| `mods` | Gli `id` delle mod che questa sostituisce: le loro schede non si vedono più. |
| `what` | Come chiamarle nei messaggi: «Ho tolto i vecchi file di ZomBOT e Admin-Scorte». |
| `files` | I vecchi file da togliere quando ci sono: esattamente questi, solo file, mai cartelle. Il launcher li legge dal `mods.json` del ramo `main`, quindi si cambiano con un commit. |

**Perché ZomBOT e Admin-Scorte restano anche in `mods`, come «disattivata».** I launcher 1.0.1 non conoscono `replaces` e lo saltano, ma leggono ancora `mods`. Accettano solo gli stati «installabile» e «disattivata», e ogni mod deve avere i suoi file nel pacchetto: con uno stato nuovo, o senza le cartelle `zombot/` e `admin-scorte/`, non riuscirebbero a leggere la release e non proporrebbero nemmeno l'aggiornamento. Così invece mostrano ZomBOT (Moon) da installare e le due vecchie «Disattivate», con il motivo, e si aggiornano alla 1.0.2, che fa il resto. Quando nessuno usa più la 1.0.1, quelle due voci e le loro cartelle si possono togliere.

Il campo `launcher` in cima a `mods.json` è la versione del launcher (diventa anche la versione dell'exe). Alzalo quando cambi il codice del launcher: chi ha una versione più vecchia riceve l'aggiornamento.

## Versioni

Ogni release pubblica una versione di ogni mod: il suo `mods.json` (allegato alla release, con le versioni già scritte) dice quali. Il launcher legge i `mods.json` di tutte le release e mette nel menu di ogni mod le sue versioni, la più nuova in cima; una versione si installa dal `moon-mods.zip` della release più recente che la contiene.

Non servono tag in più né un elenco da tenere a mano: basta alzare il file `VERSION` della mod quando la si cambia, e pubblicare la release. Una release che non cambia una mod non aggiunge niente al suo menu.

## Disattivare o riattivare una mod

In `mods.json` sul ramo `main`:

```json
"state": "disattivata", "stateNote": "Per ora sul server è disattivata.",
```

Si fa il commit, e al prossimo avvio ogni launcher la mostra come «Disattivata»: non serve una release né un launcher nuovo. GitHub tiene il file in cache fino a 5 minuti. Per riattivarla, `"state": "installabile"`. Senza connessione il launcher usa l'ultimo stato che ha letto.

## Pubblicare una release

Una release non deve mai essere visibile senza `MoonLauncher.exe`: GitHub aggiunge sempre «Source code (zip)», che sono i sorgenti del repo, e chi arriva sulla pagina prima dell'exe scarica quello. Quindi si prepara la release come bozza, si allegano i file, e solo alla fine la si pubblica:

1. Il tag sul commit da pubblicare, con la versione di `launcher` in `mods.json`:

   ```bash
   git tag v1.0.1 origin/main
   ```

   ```bash
   git push origin v1.0.1
   ```

2. La release come bozza. Le note diventano la notizia nel launcher e cominciano sempre con la riga «Scarica **MoonLauncher.exe** (non "Source code")»:

   ```bash
   gh release create v1.0.1 --draft --verify-tag --title "Moon 1.0.1" --notes-file note.md
   ```

3. Il workflow [`.github/workflows/launcher.yml`](../.github/workflows/launcher.yml) compila `MoonLauncher.exe`, prepara `moon-mods.zip` e li allega alla bozza insieme a `mods.json`, in pochi minuti:

   ```bash
   gh workflow run launcher.yml -f tag=v1.0.1
   ```

4. Quando nella bozza ci sono i tre file, la si pubblica:

   ```bash
   gh release edit v1.0.1 --draft=false --latest
   ```

Pubblicando, il workflow parte di nuovo: se l'exe c'è già non tocca niente. Se invece una release viene pubblicata senza file, li allega lui, ma per qualche minuto la pagina resta senza exe.

## Compilare e provare

```bash
dotnet publish launcher/Moon.csproj -c Release -o out
```

```bash
pwsh launcher/tools/impacchetta.ps1 -Out out
```

Il primo comando crea `out/MoonLauncher.exe`, il secondo `out/moon-mods.zip` e `out/mods.json`.

Per provarlo senza toccare il gioco vero ci sono alcune opzioni da riga di comando:

| Opzione | |
| --- | --- |
| `--gioco <cartella>` | la cartella del gioco: una finta basta che abbia `ProjectZomboid64.exe` e `media\lua\client` |
| `--zomboid <cartella>` | al posto di `%UserProfile%\Zomboid` |
| `--dati <cartella>` | al posto di `%LocalAppData%\Moon` |
| `--sorgente <cartella>` | prende le mod da una copia locale del repo invece che da GitHub |
| `--pacchetto <cartella>` | il pacchetto di Jukebox (Moon) da una cartella di `tools/jukebox build` invece che da GitHub |
| `--api <url>` | l'indirizzo delle API di GitHub (per un finto server) |
| `--prova` | non avvia il gioco e non cerca il gioco in Steam: usa solo `--gioco` (dopo GIOCA il launcher si chiude come sempre) |
| `--prova-errore` | come `--prova`, ma l'avvio del gioco non riesce: per vedere l'errore |

## Grafica

Lo sfondo, la luna, l'icona e lo splash sono disegnati da [`art/genera_sfondo.py`](art/genera_sfondo.py), solo con rumore e forme e un seme fisso: nessuna immagine presa da fuori, quindi sono di Moon come il resto del repo. Per cambiarli si modifica lo script e lo si rilancia (`python launcher/art/genera_sfondo.py`). La scheda di Silenziatori usa il poster della mod stessa.

Il font è Bahnschrift, quello di Windows 10 e 11; le icone sono Segoe Fluent Icons e Segoe MDL2 Assets, anche loro di Windows.

## Note

- **Il nome è `MoonLauncher.exe` e non `Moon.exe`.** Bitdefender blocca qualsiasi file chiamato `Moon.dll`, qualunque cosa contenga, e il compilatore non riesce nemmeno a finire.
- **«Windows ha protetto il PC».** L'exe non è firmato, quindi al primo avvio SmartScreen avvisa: «Ulteriori informazioni», poi «Esegui comunque». Gli aggiornamenti successivi li scarica il launcher stesso e non fanno comparire l'avviso.
- **I file del gioco.** Se Windows non lascia scrivere nella cartella del gioco, il launcher propone «Riavvia come amministratore».
