# Jukebox (Moon): aggiungere un CD in 5 passaggi

La musica dei jukebox la scegli tu, fuori dal gioco. Il builder la prepara, la cifra e la pubblica; il launcher di
ogni giocatore la scarica da solo. Non si scrive Lua e non si fa una mod nuova.

**Cosa serve sul PC** (una volta): Python con Pillow, numpy e cryptography (`python -m pip install pillow numpy
cryptography`), ffmpeg (`winget install Gyan.FFmpeg.Essentials`), `gh` collegato a GitHub (`gh auth login`) e `ssh`
verso cirene (`ssh m900-remote` deve funzionare). I comandi si lanciano dalla radice del repo zomboid-moon.

**La cartella della musica** sta fuori dal repo, per esempio `C:\Users\<te>\Moon\musica`. Lì il builder tiene anche
`jukebox.lock.json` (i numeri di album e brani: non cancellarlo) e `jukebox.key` (la chiave della musica: non
pubblicarla, non perderla). Fanne una copia di sicurezza ogni tanto: se ne manca uno dei due, il builder si ferma
invece di rifare i numeri (i CD nei salvataggi suonerebbero un altro album) o la chiave.

## 1. Metti l'album nella cartella

Una cartella per album dentro `albums`, con i brani (mp3, flac, ogg, wav, m4a, opus), una copertina facoltativa (png
o jpg, quadrata è meglio) e `album.json`:

```text
musica/
  albums/
    estate-1993/
      album.json
      cover.jpg
      01.mp3
      02.flac
```

```json
{
  "id": "estate-1993",
  "title": "Estate 1993",
  "artist": "Artisti vari",
  "year": 1993,
  "cover": "cover.jpg",
  "lootWeight": 1.0,
  "tracks": [
    { "id": "primo-brano", "title": "Primo brano", "artist": "Artista A", "file": "01.mp3" },
    { "id": "secondo-brano", "title": "Secondo brano", "artist": "Artista B", "file": "02.flac" }
  ]
}
```

- `id` di album e brani: minuscole, cifre e trattini, al massimo 40. **Non cambiarli più**: sono il CD nei salvataggi.
- `title` e `artist` come li vuoi vedere nel gioco (accenti compresi), al massimo 80 caratteri. `artist` del brano è
  facoltativo: senza, si usa quello dell'album.
- `lootWeight` da 0 a 10: quanto spesso si trova rispetto agli altri album (0: mai nel bottino, solo dagli admin).
- `archived: true` toglie l'album dal bottino e dalla finestra degli admin, ma i CD già trovati continuano a suonare.
- Un brano dura da 5 secondi a 30 minuti.

## 2. Controlla

```bash
python -m tools.jukebox validate --source C:\Users\<te>\Moon\musica
```

Dice cosa non va e dove (file mancanti, formati, id doppi, titoli troppo lunghi, file fuori dalla cartella). Per
vedere cosa cambierebbe senza scrivere niente:

```bash
python -m tools.jukebox build --source C:\Users\<te>\Moon\musica --out C:\Users\<te>\Moon\dist --dry-run
```

## 3. Costruisci il pacchetto

```bash
python -m tools.jukebox build --source C:\Users\<te>\Moon\musica --out C:\Users\<te>\Moon\dist
```

Converte ogni brano in OGG mono con il volume uniforme, lo taglia in pezzi da 10 secondi, fa icone e copertine,
cifra l'audio album per album e scrive `dist\<versione>` (la versione è un'impronta del contenuto). I brani già
convertiti non si rifanno, e i pezzi che nessun brano usa più si tolgono dalla cache. Se qualcosa va storto non
scrive niente e il pacchetto di prima resta com'era. Le copertine si girano come dice la fotocamera e le parti
trasparenti diventano bianche; una copertina che non si apre ferma tutto prima di convertire l'audio.

Il builder si ferma, apposta, quando:
- **manca `jukebox.lock.json` o `jukebox.key`** in una cartella già costruita: rimettili dalla copia di sicurezza (per
  la chiave c'è anche `--new-key`, sotto);
- **l'audio di un brano è cambiato**: se è lo stesso brano rifatto, `--replace estate-1993/primo-brano`; se è un altro
  brano, dagli un id nuovo;
- **manca un album o un brano che c'era**: i CD possono essere nei salvataggi. Rimettilo (anche con `"archived": true`),
  oppure, se sei sicuro, `--forget estate-1993` o `--forget estate-1993/primo-brano`: quei CD diventano oggetti
  sconosciuti.

## 4. Provalo in single player (facoltativo)

```bash
python -m tools.jukebox install --package C:\Users\<te>\Moon\dist\<versione> --source C:\Users\<te>\Moon\musica
```

Installa la mod con musica e chiave in `%UserProfile%\Zomboid\mods\JukeboxMoon`. Nel gioco: Mod, attiva «Jukebox
(Moon)», nuova partita, trova un jukebox con la corrente, tasto destro, «Jukebox». I CD li crei dalla finestra di
ZomBOT, pulsante «Jukebox» (in single player sei admin).

## 5. Pubblica

```bash
python -m tools.jukebox publish --package C:\Users\<te>\Moon\dist\<versione> --source C:\Users\<te>\Moon\musica
```

- Prima confronta i numeri degli album con il catalogo già pubblicato: se il pacchetto dà a un album il numero di un
  altro si ferma (la cartella della musica ha perso `jukebox.lock.json`).
- Carica su GitHub, nella pre-release `jukebox` del repo, solo i file che mancano o che GitHub non ha per intero, e
  per ultimo l'elenco: i launcher prendono la versione nuova al prossimo avvio e scaricano solo gli album cambiati.
- Copia sul server (cirene) motore ed elenco dei CD in `Zomboid/mods/JukeboxMoon`, e la chiave. La copia di prima resta
  in `Zomboid/JukeboxMoon-publish/old`, fuori da `mods` (due cartelle della stessa mod in `mods` confonderebbero il
  gioco).
- **Poi riavvia il server, a server vuoto**: il gioco carica i CD nuovi solo all'avvio. I giocatori devono riaprire il
  launcher (GIOCA aggiorna da solo) prima di entrare.

`--dry-run` mostra i comandi senza eseguirli; `--no-github` o `--no-server` fanno una parte sola; `--prune` toglie da
GitHub i file che nessuno degli ultimi tre elenchi usa.

## I CD del gioco, con l'audio di Radio Voices

I 69 CD che il gioco mette nel mondo non hanno audio: sono righe di testo. La mod Radio Voices (Steam Workshop
3828360540, di Espaidi) li canta e li legge. L'importatore ne fa un album della tua cartella della musica per ogni CD
del gioco che Radio Voices copre, e da lì quei dischi suonano nel jukebox: quelli che i giocatori trovano nel mondo,
senza oggetti nuovi.

1. Procurati la mod (per esempio iscrivendoti dal Workshop: la cartella è
   `steamapps\workshop\content\108600\3828360540`). **Il permesso di Espaidi lo chiedi tu.**
2. Importa:

   ```bash
   python -m tools.jukebox import-radiovoices --radiovoices <cartella di Radio Voices> --out C:\Users\<te>\Moon\musica
   ```

   Scrive (e riscrive) solo le cartelle `albums\cd-*` che ha fatto lui (hanno il file `.import-radiovoices`): i tuoi
   album non li tocca, anche se si chiamano `cd-…`, e se qualcosa va storto a metà non cambia niente. Con la versione 1.1.2 di Radio
   Voices sono 61 CD su 69, 37 canzoni e 24 letture, circa 89 minuti e 63 MB. Restano muti Carmina Burana, Constant
   Worship 1 e 2, You're Gone, Who's Better?, Sarcastic, Raps for Christ e Reasons for War: Radio Voices non li canta.
3. Poi come sempre `build` e `publish` (passi 3 e 5). Questi album non finiscono nel bottino (i dischi ci sono già)
   e dalla finestra degli admin si creano come i CD del gioco, con la loro registrazione.

Se Radio Voices si aggiorna e una canzone cambia, il builder si ferma come per ogni brano cambiato: `--replace
cd-xxxxxxxx/s-xxxxxxxx`. Alcune canzoni sono vere (dei loro autori): la musica resta fuori da git, e su GitHub va solo
cifrata.

## Domande

**Un giocatore nuovo non sente niente.** È normale la prima volta: la chiave della musica gliela dà il server quando
entra. Dalla volta dopo il launcher scarica la musica da solo.

**La chiave è finita in giro.** `build --new-key` ne fa una nuova e ricifra tutto; poi `publish`. I giocatori
riceveranno la nuova entrando, e il launcher riscaricherà la musica. La vecchia resta accanto come
`jukebox.key.<id>`.

**Tornare indietro.** Ogni versione resta in `dist`: `publish` di quella vecchia la rimette (GitHub tiene i file
degli ultimi elenchi; con `--prune` solo gli ultimi tre). Solo fra pacchetti con la stessa chiave: `publish` controlla
il pacchetto con `jukebox.key`.

**La musica di prova.** `python -m tools.jukebox demo --out C:\Users\<te>\Moon\musica-demo` scrive due album e tre
brani fatti con dei numeri (liberi, di nessuno): per provare tutto senza musica vera.

**Le licenze dei brani** sono responsabilità di chi li pubblica: il repo non contiene mai musica, e la release di
GitHub ha solo l'audio cifrato.
