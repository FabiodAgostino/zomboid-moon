"""publish and install: where a package goes.

publish (the admin, when the package is ready):
  - GitHub: the pre-release «jukebox» of the repo (the launcher never takes a pre-release for its own). The assets
    are named by their content (catalog-<hash>.zip, a<album>-<hash>.jbm): one already there, fully uploaded, with the
    same size and SHA-256, is not uploaded again. Then manifest-<version>.json, and last manifest.json (replaced): a
    launcher never sees a manifest whose files are not there yet. Before anything, the published manifest.json is
    compared with this one: a package that gives an album's number to another album is refused (the numbers are the
    CDs in the saves). --prune removes the assets that none of the last three manifests, nor this one, uses.
  - cirene, with ssh and scp: the engine (mods/JukeboxMoon of this repo) and the public catalogue in
    Zomboid/mods/JukeboxMoon, and the key in Zomboid/Lua/JukeboxMoon_server_key.txt (only the owner can read it). The
    new copy is prepared in Zomboid/JukeboxMoon-publish/new and the one before stays in Zomboid/JukeboxMoon-publish/old:
    never in mods, where the game would find two mods with the same id and could load either
    (ZomboidFileSystem: modIdToDir.put for every mod.info it finds, 42.21). The server loads them at its next start.

install (to try in single player, on this computer): engine, catalogue and the audio opened with the key in
<Zomboid>/mods/JukeboxMoon (prepared next to mods and swapped in), and the key where the game's server side reads it.
"""

from __future__ import annotations

import json
import posixpath
import shlex
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from . import package
from .audio import rename
from .build import REPO
from .source import SourceError

RELEASE = "jukebox"
ENGINE = REPO / "mods" / "JukeboxMoon"
KEEP = 3
ASIDE = "JukeboxMoon-publish"      # next to mods: the new copy while it travels, and the one before


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


def _uploaded(asset: dict | None, size: int, sha: str) -> bool:
    """An asset on GitHub that really is this file: uploaded to the end, same size and, when GitHub says it, same
    SHA-256 (an upload that stopped halfway leaves an asset that is not «uploaded»)."""
    if not asset or asset.get("state", "uploaded") != "uploaded" or asset.get("size") != size:
        return False
    digest = asset.get("digest")
    return not digest or digest.lower() == f"sha256:{sha}"


def _published(gh: str, log) -> dict | None:
    """The manifest.json on GitHub now, or None."""
    got = _run([gh, "release", "download", RELEASE, "-p", "manifest.json", "-O", "-"], False, log, check=False)
    if got.returncode != 0:
        return None
    try:
        data = json.loads(got.stdout)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def check_numbers(published: dict | None, manifest: dict) -> None:
    """The same number must stay the same album: a CD in a save is its number (JukeboxMoon.CD_<n>, the tracks' sounds).
    A package that disagrees comes from a music folder that lost jukebox.lock.json."""
    if not published:
        return
    before = {a.get("key"): a.get("id") for a in published.get("albums", []) if isinstance(a, dict)}
    for a in manifest["albums"]:
        if a["key"] in before and before[a["key"]] != a["id"]:
            raise SourceError(
                f"Il catalogo pubblicato dà il numero {a['key']} a «{before[a['key']]}», questo a «{a['id']}»: i CD nei "
                f"salvataggi suonerebbero un altro album. La cartella della musica ha perso jukebox.lock.json? "
                f"Rimettilo dalla copia di sicurezza e rifai build.")


def _upload(gh: str, path: Path, dry_run: bool, log, attempts: int = 3) -> None:
    """--clobber takes the old file away before the new one is up: when it fails, it is tried again."""
    for attempt in range(attempts):
        try:
            _run([gh, "release", "upload", RELEASE, str(path), "--clobber"], dry_run, log)
            return
        except SourceError:
            if attempt == attempts - 1:
                raise
            time.sleep(3)


def github(folder: Path, dry_run: bool, prune: bool, log) -> None:
    gh = shutil.which("gh")
    if not gh:
        raise SourceError("Manca gh (GitHub CLI): installalo e fai gh auth login.")
    folder = Path(folder)
    manifest = _manifest(folder)
    version = manifest["catalogVersion"]
    view = _run([gh, "release", "view", RELEASE, "--json", "assets"], False, log, check=False)
    if view.returncode != 0:
        _run([gh, "release", "create", RELEASE, "--prerelease", "--title", "Jukebox (Moon): la musica",
              "--notes", "La musica dei jukebox di Moon, cifrata: la installa il launcher. Non scaricare niente da "
                         "qui a mano."], dry_run, log)
        have: dict[str, dict] = {}
    else:
        have = {a["name"]: a for a in json.loads(view.stdout or "{}").get("assets", [])}
        check_numbers(_published(gh, log), manifest)
    entries = [manifest["catalog"]] + manifest["albums"]
    todo = [e["asset"] for e in entries if not _uploaded(have.get(e["asset"]), e["size"], e["sha256"])]
    for name in todo:
        _upload(gh, folder / name, dry_run, log)
    with tempfile.TemporaryDirectory() as tmp:
        versioned = Path(tmp) / f"manifest-{version}.json"
        shutil.copyfile(folder / "manifest.json", versioned)
        _upload(gh, versioned, dry_run, log)
    _upload(gh, folder / "manifest.json", dry_run, log)
    log(f"GitHub: {len(todo)} file {'da caricare' if dry_run else 'caricati'}, {len(entries) - len(todo)} c'erano già.")
    if prune:
        _prune(gh, manifest, dry_run, log)


def _prune(gh: str, manifest: dict, dry_run: bool, log) -> None:
    """Remove the assets that neither this package nor the last KEEP manifests (manifest-<version>.json, by upload
    date) use. With --dry-run it only says which."""
    view = _run([gh, "release", "view", RELEASE, "--json", "assets"], False, log, check=False)
    if view.returncode != 0:
        return
    assets = json.loads(view.stdout or "{}").get("assets", [])
    dated = sorted((a for a in assets if a["name"].startswith("manifest-")), key=lambda a: a.get("createdAt", ""),
                   reverse=True)[:KEEP]
    keep = {"manifest.json", f"manifest-{manifest['catalogVersion']}.json"} | set(_assets(manifest))
    keep |= {a["name"] for a in dated}
    for a in dated:
        got = _run([gh, "release", "download", RELEASE, "-p", a["name"], "-O", "-"], False, log, check=False)
        try:
            keep |= set(_assets(json.loads(got.stdout)))
        except (ValueError, KeyError, TypeError):
            log(f"Non riesco a leggere {a['name']}: non tolgo niente.")
            return
    gone = [a["name"] for a in assets if a["name"] not in keep]
    for name in gone:
        _run([gh, "release", "delete-asset", RELEASE, name, "--yes"], dry_run, log)
    log(f"GitHub: {'toglierei' if dry_run else 'tolti'} {len(gone)} file che nessuno degli ultimi {KEEP} cataloghi usa.")


def stage_mod(folder: Path, target: Path, key: bytes | None) -> int:
    """The mod as it must be: engine + public catalogue (+ the audio when a key is given). Returns the files."""
    target = Path(target)
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(ENGINE, target)
    root = target.resolve()
    manifest = _manifest(folder)
    files = package.read_zip((Path(folder) / manifest["catalog"]["asset"]).read_bytes())
    if key is not None:
        for album in manifest["albums"]:
            files.update(package.read_zip(package.decrypt(key, (Path(folder) / album["asset"]).read_bytes())))
    for path, data in files.items():
        out = target / path
        if ".." in Path(path).parts or Path(path).is_absolute() or not out.resolve().is_relative_to(root):
            raise SourceError(f"Percorso non valido nel pacchetto: {path}")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
    return len(files)


def server(folder: Path, music: Path, host: str, mods: str, lua: str, dry_run: bool, log) -> None:
    key = package.read_key(music, create=False)
    if _manifest(folder)["keyId"] != package.key_id(key):
        raise SourceError("La chiave della cartella della musica non è quella del pacchetto.")
    mods = mods.rstrip("/")
    aside = posixpath.join(posixpath.dirname(mods) or ".", ASIDE)
    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / "JukeboxMoon"
        count = stage_mod(folder, staged, None)
        q = shlex.quote
        _run(["ssh", host, f"mkdir -p {q(mods)} {q(lua)} {q(aside)} && rm -rf {q(aside + '/new')}"], dry_run, log)
        _run(["scp", "-r", "-q", str(staged), f"{host}:{aside}/new"], dry_run, log)
        live, old, new = q(mods + "/JukeboxMoon"), q(aside + "/old"), q(aside + "/new")
        _run(["ssh", host, f"rm -rf {old} && if [ -d {live} ]; then mv {live} {old}; fi && mv {new} {live}"],
             dry_run, log)
        key_file = f"{lua}/JukeboxMoon_server_key.txt"
        _run(["ssh", host, f"umask 077 && cat > {q(key_file + '.tmp')} && mv {q(key_file + '.tmp')} {q(key_file)}"],
             dry_run, log, input_text=f"{key.hex()}\n{package.key_id(key)}\n")
    log(f"Server: {count} file del catalogo più il motore in {mods}/JukeboxMoon, e la chiave (la copia di prima in "
        f"{aside}/old). Si caricano al prossimo avvio del server: riavvialo a server vuoto.")


def install(folder: Path, music: Path, zomboid: Path, log) -> None:
    key = package.read_key(music, create=False)
    problems = package.verify(folder, key)
    if problems:
        raise SourceError("Il pacchetto non torna: " + "; ".join(problems))
    zomboid = Path(zomboid)
    target = zomboid / "mods" / "JukeboxMoon"
    aside = zomboid / ASIDE
    aside.mkdir(parents=True, exist_ok=True)
    count = stage_mod(folder, aside / "new", key)
    shutil.rmtree(aside / "old", ignore_errors=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        rename(target, aside / "old")
    rename(aside / "new", target)
    shutil.rmtree(aside, ignore_errors=True)
    lua = zomboid / "Lua"
    lua.mkdir(parents=True, exist_ok=True)
    (lua / "JukeboxMoon_server_key.txt").write_text(f"{key.hex()}\n{package.key_id(key)}\n", encoding="ascii")
    log(f"Installata in {target}: il motore e {count} file del catalogo, con l'audio. Attiva «Jukebox (Moon)» fra "
        f"le mod e prova in una partita in single player.")
