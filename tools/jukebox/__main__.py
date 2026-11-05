"""Jukebox (Moon): il builder dei CD. Dalla radice del repo zomboid-moon:

    python -m tools.jukebox validate --source <musica>
    python -m tools.jukebox build    --source <musica> --out <dist> [--dry-run] [--replace album/brano] [--forget id]
    python -m tools.jukebox manifest --package <dist>/<versione> [--source <musica>]
    python -m tools.jukebox install  --package <dist>/<versione> --source <musica> [--zomboid <cartella>]
    python -m tools.jukebox publish  --package <dist>/<versione> --source <musica> [--no-github] [--no-server]
    python -m tools.jukebox demo     --out <cartella>
    python -m tools.jukebox import-radiovoices --radiovoices <mod Radio Voices> --out <musica> [--game <gioco>]

Servono Python con Pillow, numpy (solo demo) e cryptography, e ffmpeg con ffprobe. La guida è README_ADMIN.md.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import build, demo, package, publish, radiovoices
from .source import SourceError


def _log(text: str) -> None:
    print(text, flush=True)


def _changes(report: build.Report) -> None:
    c = report.changes
    groups = [("album nuovi", c.new_albums), ("brani nuovi", c.new_tracks), ("brani sostituiti", c.changed_tracks),
              ("brani uguali", c.unchanged_tracks), ("dimenticati", c.forgotten), ("archiviati", c.archived)]
    for title, items in groups:
        if items:
            shown = ", ".join(items[:12]) + (f" e altri {len(items) - 12}" if len(items) > 12 else "")
            _log(f"  {title} ({len(items)}): {shown}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m tools.jukebox", description="Il builder dei CD di Jukebox (Moon).")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("validate", help="controlla la cartella della musica senza scrivere niente")
    p.add_argument("--source", required=True, type=Path)

    p = sub.add_parser("build", help="fa il pacchetto del catalogo")
    p.add_argument("--source", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--dry-run", action="store_true", help="dice cosa cambierebbe, senza scrivere niente")
    p.add_argument("--replace", action="append", default=[], metavar="ALBUM/BRANO",
                   help="l'audio del brano è cambiato apposta: tiene il suo numero")
    p.add_argument("--forget", action="append", default=[], metavar="ALBUM[/BRANO]",
                   help="toglie davvero un album o un brano (i CD nei salvataggi diventano sconosciuti)")
    p.add_argument("--new-key", action="store_true", help="una chiave nuova: tutto l'audio si ricifra")
    p.add_argument("--workers", type=int, default=0)

    p = sub.add_parser("manifest", help="controlla un pacchetto contro il suo manifest")
    p.add_argument("--package", required=True, type=Path)
    p.add_argument("--source", type=Path, help="con la cartella della musica controlla anche la chiave")

    p = sub.add_parser("install", help="installa il pacchetto su questo PC, per provarlo in single player")
    p.add_argument("--package", required=True, type=Path)
    p.add_argument("--source", required=True, type=Path)
    p.add_argument("--zomboid", type=Path, default=Path.home() / "Zomboid")

    p = sub.add_parser("publish", help="pubblica il pacchetto: release jukebox di GitHub e mod del server")
    p.add_argument("--package", required=True, type=Path)
    p.add_argument("--source", required=True, type=Path)
    p.add_argument("--no-github", action="store_true")
    p.add_argument("--no-server", action="store_true")
    p.add_argument("--host", default="m900-remote")
    p.add_argument("--mods", default="server/zomboid/live/Zomboid/mods", help="sul server, dalla home")
    p.add_argument("--lua", default="server/zomboid/live/Zomboid/Lua", help="sul server, dalla home")
    p.add_argument("--prune", action="store_true", help="toglie da GitHub i file che nessun catalogo recente usa")
    p.add_argument("--dry-run", action="store_true", help="mostra i comandi senza eseguirli")

    p = sub.add_parser("demo", help="scrive una cartella di musica di prova (due album, tre brani)")
    p.add_argument("--out", required=True, type=Path)

    p = sub.add_parser("import-radiovoices", help="i CD del gioco con l'audio di Radio Voices, nella cartella della musica")
    p.add_argument("--radiovoices", required=True, type=Path, help="la cartella della mod Radio Voices")
    p.add_argument("--out", required=True, type=Path, help="la cartella della musica (fuori dal repo)")
    p.add_argument("--game", type=Path, default=radiovoices.STEAM_GAME, help="la cartella di Project Zomboid")

    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            albums, _ = build.validate(args.source)
            _log(f"Tutto a posto: {len(albums)} album, {sum(len(a.tracks) for a in albums)} brani.")
        elif args.command == "build":
            report = build.build(args.source, args.out, set(args.replace), set(args.forget), args.dry_run,
                                 args.new_key, args.workers)
            if args.dry_run:
                _log(f"Prova: {report.albums} album, {report.tracks} brani. Cambierebbe:")
                _changes(report)
            else:
                _log(f"Pacchetto {report.version} in {report.folder}: {report.albums} album, {report.tracks} brani, "
                     f"{report.seconds // 60} minuti, {report.bytes / 1e6:.1f} MB.")
                _changes(report)
        elif args.command == "manifest":
            key = package.read_key(args.source, create=False) if args.source else None
            problems = package.verify(args.package, key)
            manifest = json.loads((args.package / "manifest.json").read_text(encoding="utf-8"))
            if problems:
                for problem in problems:
                    _log(f"  {problem}")
                return 1
            _log(f"Il pacchetto {manifest['catalogVersion']} torna: {1 + len(manifest['albums'])} file, "
                 f"motore {manifest['packageVersion']}, chiave {manifest['keyId']}"
                 f"{' (verificata)' if key else ''}.")
        elif args.command == "install":
            publish.install(args.package, args.source, args.zomboid, _log)
        elif args.command == "publish":
            key = package.read_key(args.source, create=False)
            problems = package.verify(args.package, key)
            if problems:
                raise SourceError("Il pacchetto non torna: " + "; ".join(problems))
            if not args.no_github:
                publish.github(args.package, args.dry_run, args.prune, _log)
            if not args.no_server:
                publish.server(args.package, args.source, args.host, args.mods, args.lua, args.dry_run, _log)
        elif args.command == "import-radiovoices":
            plans = radiovoices.import_cds(args.radiovoices, args.out, args.game, _log)
            done = [p for p in plans if p.songs or p.read]
            _log(f"{len(done)} CD del gioco su {len(plans)} in {args.out / 'albums'} (cartelle cd-*): "
                 f"{sum(len(p.songs) for p in done)} canzoni, {sum(1 for p in done if p.read)} letture.")
        elif args.command == "demo":
            out = demo.make(args.out)
            _log(f"Musica di prova in {out}.")
    except (SourceError, ValueError) as e:
        _log(f"Errore: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
