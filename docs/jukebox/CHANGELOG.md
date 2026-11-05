# Jukebox (Moon): modifiche

## 1.0.0 (5 novembre 2026, non pubblicata, mai provata nel gioco)

- I jukebox del mondo diventano, alla prima apertura, jukebox con un contenitore: i CD di Moon si mettono e si tolgono
  dalla finestra del bottino. Al massimo 20 CD (opzione del server).
- Finestra «Jukebox»: stato, brano con artista, album e tempo, copertina, elenco dei brani, Riproduci, Ferma,
  Precedente, Successiva, riproduzione casuale, volume solo per sé.
- Decide il server: comandi, fine del brano, corrente, CD tolti. I client suonano pezzi da 10 secondi all'ora del
  server: chi arriva o torna sente lo stesso punto degli altri.
- Noia e stress tolti a chi è vicino a un jukebox che suona (10 caselle, stesso piano, 4 punti di noia e 0,02 di stress
  per ora di gioco), niente per chi è sordo, metà per chi sente poco.
- CD nel bottino (raro) e creati dagli admin dalla finestra di ZomBOT.
- Il builder dei CD (`tools/jukebox`): validate, build, manifest, install, publish, demo.
- I CD del gioco suonano nel jukebox: `import-radiovoices` fa un album per ognuno dall'audio di Radio Voices (61 su 69),
  e il jukebox li riconosce dalla registrazione.
- Il launcher 1.0.3 scarica il catalogo pubblico e, con la chiave che il gioco dà a chi entra su Moon, la musica cifrata.
- Il CD unico: un album con `"unique"` in `album.json` esiste in una sola copia in tutta la storia del server. Lo
  porta un corridore ucciso da un giocatore (uno su `oneIn`, per «Love storii...» 300), mai il bottino né gli admin;
  trovato non esce più, e il server lo scrive in `jukeboxmoon_unique.json` perché ZomBOT lo annunci.
- Revisione completa (stesso giorno), verificata nel jar della 42.21:
  - mod: ogni client suona il pezzo solo per sé (`playSound` lo rimandava agli altri, che lo avrebbero sentito due
    volte); funziona in single player; la regola «solo CD» torna quando la casella si ricarica; il suono d'ambiente
    del gioco tace mentre suona la nostra musica; titolo «Jukebox» nella finestra del bottino; un ordine casuale nuovo
    a ogni accensione; limite su `hello` e `ping`; volume salvato solo quando il cursore si ferma; avvisi nella
    finestra giusta; voce del menu anche con il controller;
  - audio mono: metà della memoria del gioco (che tiene ogni pezzo sentito fino alla chiusura) e un quarto in meno da
    scaricare;
  - builder: chiave nuova con file nuovi e la vecchia tenuta; numeri e chiave scritti prima del pacchetto, e una
    cartella che ne ha perso uno si ferma; un album alla volta in memoria; copertine girate, trasparenti e a 16 bit;
    importatore che lascia stare gli album dell'admin e conta le righe diverse; `publish` che controlla i numeri e i
    file su GitHub e tiene la copia di riserva fuori da `mods`;
  - launcher: un pacchetto illeggibile non cancella più catalogo e musica; togliere e rimettere la mod nella stessa
    sessione; impronte salvate dopo ogni controllo; limiti di attesa sui download; la pre-release non è fra le novità.
