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
- Il launcher 1.0.3 scarica il catalogo pubblico e, con la chiave che il gioco dà a chi entra su Moon, la musica cifrata.
