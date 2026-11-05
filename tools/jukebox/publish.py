"""publish and install: where a package goes.

publish (the admin, when the package is ready):
  - GitHub: the pre-release «jukebox» of the repo (the launcher never takes a pre-release for its own). The assets
    named by content (catalog-<hash>.zip, a<album>-<hash>.jbm) are uploaded only when missing, then
    manifest-<version>.json, and last manifest.json (replaced): a launcher never sees a manifest whose files are not
    there yet. --prune removes the assets that none of the last three manifests uses.
  - cirene, with ssh and scp: the engine (mods/JukeboxMoon of this repo) and the public catalogue in
    Zomboid/mods/JukeboxMoon (in JukeboxMoon.new first, then swapped), and the key in
    Zomboid/Lua/JukeboxMoon_server_key.txt (only the owner can read it). The server loads them at its next start.

install (to try in single player, on this computer): engine, catalogue and the audio opened with the key in
<Zomboid>/mods/JukeboxMoon, and the key where the game's server side reads it.
"""

from __future__ import annotations

import json
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

from . import package
from .build import REPO
from .source import SourceError

RELEASE = "jukebox"
ENGINE = REPO / "mods" / "JukeboxMoon"
KEEP = 3


def _run(args: list[str], dry_run: bool, log, input_text: str | None = None, check: bool = True):
    shown = " ".join(shlex.quote(a) for a in args)
    if dry_run:
        log(f"(prova) {shown}")
        return None
    result = subprocess.run(args, input=input_text, capture_output=True, text=True, encoding="utf-8",
                            errors="replace", cwd=REPO)
    if check and result.returncode != 0:
        raise SourceError(f"Non è riuscito: {shown}\n{result.stderr.strip()[-800:]}")
    return result


def _manifest(folder: Path) -> dict:
    return json.loads((Path(folder) / "manifest.json").read_text(encoding="utf-8"))


def _assets(manifest: dict) -> list[str]:
    return [manifest["catalog"]["asset"]] + [a["asset"] for a in manifest["albums"]]


def github(folder: Path, dry_run: bool, prune: bool, log) -> None:
    gh = shutil.which("gh")
    if not gh:
        raise SourceError("Manca gh (GitHub CLI): installalo e fai gh auth login.")
    manifest = _manifest(folder)
    version = manifest["catalogVersion"]
    view = _run([gh, "release", "view", RELEASE, "--json", "assets"], dry_run=False, log=log, check=False)
    if view.returncode != 0:
        _run([gh, "release", "create", RELEASE, "--prerelease", "--title", "Jukebox (Moon): la musica",
              "--notes", "La musica dei jukebox di Moon, cifrata: la installa il launcher. Non scaricare niente da "
                         "qui a mano."], dry_run, log)
        have: set[str] = set()
    else:
        have = {a["name"] for a in json.loads(view.stdout or "{}").get("assets", [])}
    missing = [n for n in _assets(manifest) if n not in have]
    for name in missing:
        _run([gh, "release", "upload", RELEASE, str(folder / name)], dry_run, log)
    versioned = Path(tempfile.mkdtemp()) / f"manifest-{version}.json"
    shutil.copyfile(folder / "manifest.json", versioned)
    _run([gh, "release", "upload", RELEASE, str(versioned), "--clobber"], dry_run, log)
    _run([gh, "release", "upload", RELEASE, str(folder / "manifest.json"), "--clobber"], dry_run, log)
    log(f"GitHub: {len(missing)} file caricati, {len(_assets(manifest)) - len(missing)} c'erano già.")
    if prune and not dry_run:
        _prune(gh, log)


def _prune(gh: str, log) -> None:
    """Remove the assets that none of the last KEEP manifests uses (manifest-<version>.json, by upload date)."""
    view = subprocess.run([gh, "release", "view", RELEASE, "--json", "assets"], capture_output=True, text=True,
                          encoding="utf-8", cwd=REPO, check=True)
    assets = json.loads(view.stdout or "{}").get("assets", [])
    dated = sorted((a for a in assets if a["name"].startswith("manifest-")), key=lambda a: a.get("createdAt", ""),
                   reverse=True)[:KEEP]
    keep = {"manifest.json"} | {a["name"] for a in dated}
    for a in dated:
        data = subprocess.run([gh, "release", "download", RELEASE, "-p", a["name"], "-O", "-"], capture_output=True,
                              cwd=REPO).stdout
        try:
            keep |= set(_assets(json.loads(data)))
        except (ValueError, KeyError):
            log(f"Non riesco a leggere {a['name']}: non tolgo niente.")
            return
    removed = 0
    for a in assets:
        if a["name"] not in keep:
            subprocess.run([gh, "release", "delete-asset", RELEASE, a["name"], "--yes"], cwd=REPO, check=True)
            removed += 1
    log(f"GitHub: tolti {removed} file che nessuno degli ultimi {KEEP} cataloghi usa.")


def stage_mod(folder: Path, target: Path, key: bytes | None) -> int:
    """The mod as it must be: engine + public catalogue (+ the audio when a key is given). Returns the files."""
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(ENGINE, target)
    manifest = _manifest(folder)
    files = package.read_zip((folder / manifest["catalog"]["asset"]).read_bytes())
    if key is not None:
        for album in manifest["albums"]:
            files.update(package.read_zip(package.decrypt(key, (folder / album["asset"]).read_bytes())))
    for path, data in files.items():
        out = target / path
        if ".." in Path(path).parts:
            raise SourceError(f"Percorso non valido nel pacchetto: {path}")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
    return len(files)


def server(folder: Path, music: Path, host: str, mods: str, lua: str, dry_run: bool, log) -> None:
    key = package.read_key(music, create=False)
    if _manifest(folder)["keyId"] != package.key_id(key):
        raise SourceError("La chiave della cartella della musica non è quella del pacchetto.")
    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / "JukeboxMoon"
        count = stage_mod(folder, staged, None)
        q = shlex.quote
        _run(["ssh", host, f"mkdir -p {q(mods)} {q(lua)} && rm -rf {q(mods + '/JukeboxMoon.new')}"], dry_run, log)
        _run(["scp", "-r", "-q", str(staged), f"{host}:{mods}/JukeboxMoon.new"], dry_run, log)
        _run(["ssh", host, f"cd {q(mods)} && rm -rf JukeboxMoon.old && "
                           f"if [ -d JukeboxMoon ]; then mv JukeboxMoon JukeboxMoon.old; fi && "
                           f"mv JukeboxMoon.new JukeboxMoon"], dry_run, log)
        key_file = f"{lua}/JukeboxMoon_server_key.txt"
        _run(["ssh", host, f"umask 077 && cat > {q(key_file + '.tmp')} && mv {q(key_file + '.tmp')} {q(key_file)}"],
             dry_run, log, input_text=f"{key.hex()}\n{package.key_id(key)}\n")
    log(f"Server: {count} file del catalogo più il motore in {mods}/JukeboxMoon, e la chiave. "
        f"Si caricano al prossimo avvio del server: riavvialo a server vuoto.")


def install(folder: Path, music: Path, zomboid: Path, log) -> None:
    key = package.read_key(music, create=False)
    problems = package.verify(folder, key)
    if problems:
        raise SourceError("Il pacchetto non torna: " + "; ".join(problems))
    target = Path(zomboid) / "mods" / "JukeboxMoon"
    count = stage_mod(folder, target, key)
    lua = Path(zomboid) / "Lua"
    lua.mkdir(parents=True, exist_ok=True)
    (lua / "JukeboxMoon_server_key.txt").write_text(f"{key.hex()}\n{package.key_id(key)}\n", encoding="ascii")
    log(f"Installata in {target}: il motore e {count} file del catalogo, con l'audio. Attiva «Jukebox (Moon)» fra "
        f"le mod e prova in una partita in single player.")
