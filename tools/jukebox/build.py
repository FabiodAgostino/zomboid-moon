"""validate and build: from the admin's music folder to a package (package.py), without ever writing half of one.

The numbers (jukebox.lock.json) and the key (jukebox.key) are written before the package takes its name: a package is
never in dist without the numbers it used. A folder that has one of the two and not the other was built before and
lost a file: the builder stops instead of giving new numbers (CDs in saves would play another album) or a new key.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from . import audio, generate, lock, package, source
from .source import SourceError

REPO = Path(__file__).resolve().parents[2]
MOD_INFO = REPO / "mods" / "JukeboxMoon" / "42" / "mod.info"


def engine_version() -> str:
    for line in MOD_INFO.read_text(encoding="utf-8").splitlines():
        if line.startswith("modversion="):
            return line.split("=", 1)[1].strip()
    raise SourceError(f"{MOD_INFO}: manca modversion.")


def outside_repo(folder: Path) -> Path:
    """The music never goes in the repo: a folder inside it is refused."""
    folder = Path(folder).resolve()
    if folder == REPO or REPO in folder.parents:
        raise SourceError("La musica non va mai nel repo: scegli una cartella fuori da zomboid-moon.")
    return folder


@dataclass
class Report:
    version: str | None
    folder: Path | None
    changes: lock.Changes
    albums: int
    tracks: int
    seconds: int
    bytes: int


def validate(music: Path) -> tuple[list[source.Album], dict[tuple[str, str], str]]:
    """Every check that does not write anything: the albums, ffmpeg, the audio readable and long enough, the covers."""
    albums = source.load(Path(music))
    audio.tools()
    hashes = {}
    for album in albums:
        if album.cover:
            try:
                generate.open_cover(album.cover.read_bytes())
            except Exception as e:
                raise SourceError(f"albums/{album.folder.name}: la copertina {album.cover.name} non si apre ({e}).") from e
        for track in album.tracks:
            audio.probe(track.path)
            hashes[(album.id, track.id)] = lock.file_sha256(track.path)
    return albums, hashes


def _key_and_lock(music: Path, new_key: bool) -> None:
    has_key, has_lock = (music / package.KEY_FILE).exists(), (music / lock.LOCK).exists()
    if has_key and not has_lock:
        raise SourceError(
            f"Manca {lock.LOCK}, ma questa cartella è già stata costruita (c'è {package.KEY_FILE}): senza, i CD nei "
            f"salvataggi cambierebbero numero. Rimettilo dalla copia di sicurezza. Se vuoi davvero ricominciare da "
            f"zero, togli anche {package.KEY_FILE}.")
    if has_lock and not has_key and not new_key:
        raise SourceError(
            f"Manca {package.KEY_FILE}, ma questa cartella è già stata costruita (c'è {lock.LOCK}). Rimettila dalla "
            f"copia di sicurezza, oppure --new-key: tutta la musica si ricifra e i giocatori la riscaricano dopo "
            f"essere entrati su Moon.")


def build(music: Path, dist: Path, replace: set[str] = frozenset(), forget: set[str] = frozenset(),
          dry_run: bool = False, new_key: bool = False, workers: int = 0) -> Report:
    music, dist = outside_repo(music), Path(dist)
    albums, hashes = validate(music)
    _key_and_lock(music, new_key)
    current = lock.read(music)
    updated, changes = lock.update(current, albums, set(replace), set(forget), hashes)
    tracks = sum(len(a.tracks) for a in albums)
    if dry_run:
        return Report(None, None, changes, len(albums), tracks, 0, 0)

    old_key = package.read_key(music, create=False) if (music / package.KEY_FILE).exists() else None
    key = package.new_key() if new_key or old_key is None else old_key
    workers = workers or max(1, min(8, (os.cpu_count() or 2) - 1))
    staging = package.Staging(dist, key)
    try:
        outs: list[generate.AlbumOut] = []
        used: set[str] = set()
        seconds = 0
        for album in albums:
            # one album at a time: its pieces are read, encrypted into its .jbm and let go
            entry = updated["albums"][album.id]
            track_outs = []
            files: dict[str, bytes] = {}
            for track in album.tracks:
                digest = hashes[(album.id, track.id)]
                used.add(audio.cache_key(digest))
                key_n = entry["tracks"][track.id]["key"]
                cut = audio.cut(track.path, digest, music, workers)
                seconds += cut.ms // 1000
                for k, piece in enumerate(cut.pieces):
                    files[generate.sound_path(key_n, k).replace("media/", "42/media/", 1)] = piece.read_bytes()
                track_outs.append(generate.TrackOut(key=key_n, id=track.id, n=track.n, title=track.title,
                                                    artist=track.artist, ms=cut.ms, segments=len(cut.pieces)))
            staging.add_album(entry["key"], album.id, files)
            outs.append(generate.AlbumOut(key=entry["key"], id=album.id, title=album.title, artist=album.artist,
                                          year=album.year, loot=album.loot, archived=album.archived, tracks=track_outs,
                                          cover=album.cover.read_bytes() if album.cover else None, media=album.media,
                                          unique=album.unique))
        outs.sort(key=lambda a: a.key)

        metadata = [{"key": a.key, "id": a.id, "title": a.title, "artist": a.artist, "year": a.year, "loot": a.loot,
                     "archived": a.archived, "media": a.media, "unique": a.unique,
                     "tracks": [vars(t) for t in a.tracks]} for a in outs]
        public = generate.public_files("", outs)
        version = package.version_of(public, staging.audio,
                                     {"albums": metadata, "engine": engine_version(), "generator": generate.VERSION,
                                      "key": package.key_id(key)})
        public[generate.CATALOG_DATA] = generate.catalog_lua(version, outs).encode("ascii")
        staged = staging.finish(version, engine_version(), public)
        problems = package.verify(staged, key)
        if problems:
            raise SourceError("Il pacchetto appena scritto non torna: " + "; ".join(problems))

        # what the folder must remember first, then the package
        if key != old_key:
            if old_key is not None:
                package.keep_old_key(music, old_key)
            package.write_key(music, key)
        lock.write(music, updated)
        folder = package.place(dist, version, staged)
    except BaseException:
        staging.discard()
        raise
    audio.prune_cache(music, used)
    size = sum(p.stat().st_size for p in folder.iterdir())
    return Report(version, folder, changes, len(albums), tracks, seconds, size)
