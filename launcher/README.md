# Il launcher di Moon

`MoonLauncher.exe` è il programma che installa, aggiorna e toglie le mod del server **Moon** e avvia Project Zomboid. Fa quello che faceva `mod-moon-server.bat`, più gli aggiornamenti: chi lo scarica una volta dalle [Release](https://github.com/FabiodAgostino/zomboid-moon/releases) non deve più scaricare ZIP.

È un solo file `.exe` (WPF, .NET 10, con il runtime dentro): non si installa niente, si apre e basta.

## Cosa fa

- **Mod come schede con un interruttore.** Accendi e la mod si installa; spegni e si toglie, dopo una domanda. Tutte sono facoltative. Una mod con `"required": true` è una che serve per entrare sul server (oggi nessuna): finché manca, GIOCA diventa **INSTALLA**.
- **Aggiornamenti.** All'avvio legge l'ultima release del repo e scarica il suo `moon-mods.zip` (una sola volta per release). Confronta ogni file installato con quello della release, byte per byte, come faceva il bat con `fc /b`. Se qualcosa è diverso la mod diventa **Da aggiornare**, e GIOCA diventa **AGGIORNA**.
- **Versione a scelta.** Accanto al nome di ogni mod c'è la sua versione: con più versioni pubblicate si apre un menu con tutte, la più nuova in cima. Una versione precedente si installa dalla release che l'aveva pubblicata; la scheda dice «versione scelta da te», e il launcher non la aggiorna da solo finché non si sceglie di nuovo l'ultima.
- **Stato: «Installabile» o «Disattivata».** Lo decide il repo (vedi [Disattivare una mod](#disattivare-o-riattivare-una-mod)). Una mod disattivata non si installa né si aggiorna. Se qualcuno ce l'ha già, il launcher lo avvisa e nella scheda offre **TOGLI**, ma non la toglie da solo: tenerla installata non fa niente di male, il gioco carica solo quello che il server chiede.
- **Le installazioni del bat.** Riconosce le mod installate con `mod-moon-server.bat` (dai file, e dalla versione scritta in `media\lua\Moon-<mod>.version`), e scrive quei file come il bat: si può passare dall'uno all'altro.
- **In home**, come il bat, una tabella con ogni mod, la sua versione e com'è sul computer: aggiornata, da aggiornare, non installata, disattivata.
- **File condivisi.** Un file che due mod mettono nello stesso posto (`ZomBotMenu.lua`, in Admin-Scorte e in ZomBOT) resta finché è installata almeno una delle due.
- **GIOCA** avvia il gioco con `steam://rungameid/108600`; senza Steam, con `ProjectZomboid64.exe`. Quando il gioco è aperto il launcher si riduce a icona e le mod non si toccano: se serve, aspetta che il gioco si chiuda.
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

Si pubblica una release su GitHub con le sue note, che diventano la notizia nel launcher. Per esempio:

```bash
gh release create v1.1.0 --title "Arriva ZomBOT" --notes-file note.md
```

Il workflow [`.github/workflows/launcher.yml`](../.github/workflows/launcher.yml) parte da solo. Compila `MoonLauncher.exe`, prepara `moon-mods.zip` e li allega alla release insieme a `mods.json`, in pochi minuti. Il workflow si può anche lanciare a mano dalla scheda Actions, indicando un tag per rifare gli allegati di una release.

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
| `--api <url>` | l'indirizzo delle API di GitHub (per un finto server) |
| `--prova` | non avvia il gioco e non cerca il gioco in Steam: usa solo `--gioco` |

## Grafica

Lo sfondo, la luna, l'icona e lo splash sono disegnati da [`art/genera_sfondo.py`](art/genera_sfondo.py), solo con rumore e forme e un seme fisso: nessuna immagine presa da fuori, quindi sono di Moon come il resto del repo. Per cambiarli si modifica lo script e lo si rilancia (`python launcher/art/genera_sfondo.py`). La scheda di Silenziatori usa il poster della mod stessa.

Il font è Bahnschrift, quello di Windows 10 e 11; le icone sono Segoe Fluent Icons e Segoe MDL2 Assets, anche loro di Windows.

## Note

- **Il nome è `MoonLauncher.exe` e non `Moon.exe`.** Bitdefender blocca qualsiasi file chiamato `Moon.dll`, qualunque cosa contenga, e il compilatore non riesce nemmeno a finire.
- **«Windows ha protetto il PC».** L'exe non è firmato, quindi al primo avvio SmartScreen avvisa: «Ulteriori informazioni», poi «Esegui comunque». Gli aggiornamenti successivi li scarica il launcher stesso e non fanno comparire l'avviso.
- **I file del gioco.** Se Windows non lascia scrivere nella cartella del gioco, il launcher propone «Riavvia come amministratore».
