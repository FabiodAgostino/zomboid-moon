"""validate and build: from the admin's music folder to a package (package.py), without ever writing half of one."""

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
    """Every check that does not write anything: the albums, ffmpeg, the audio readable and long enough."""
    albums = source.load(Path(music))
    audio.tools()
    hashes = {}
    for album in albums:
        for track in album.tracks:
            audio.probe(track.path)
            hashes[(album.id, track.id)] = lock.file_sha256(track.path)
    return albums, hashes


def build(music: Path, dist: Path, replace: set[str] = frozenset(), forget: set[str] = frozenset(),
          dry_run: bool = False, new_key: bool = False, workers: int = 0) -> Report:
    music, dist = Path(music), Path(dist)
    albums, hashes = validate(music)
    current = lock.read(music)
    updated, changes = lock.update(current, albums, set(replace), set(forget), hashes)
    tracks = sum(len(a.tracks) for a in albums)
    if dry_run:
        return Report(None, None, changes, len(albums), tracks, 0, 0)

    workers = workers or max(1, min(8, (os.cpu_count() or 2) - 1))
    outs: list[generate.AlbumOut] = []
    audio_by_album: list[tuple[int, str, dict[str, bytes]]] = []
    all_audio: dict[str, bytes] = {}
    seconds = 0
    for album in albums:
        entry = updated["albums"][album.id]
        track_outs = []
        files: dict[str, bytes] = {}
        for track in album.tracks:
            key = entry["tracks"][track.id]["key"]
            cut = audio.cut(track.path, hashes[(album.id, track.id)], music, workers)
            seconds += cut.ms // 1000
            for k, piece in enumerate(cut.pieces):
                files[generate.sound_path(key, k).replace("media/", "42/media/", 1)] = piece.read_bytes()
            track_outs.append(generate.TrackOut(key=key, id=track.id, n=track.n, title=track.title,
                                                artist=track.artist, ms=cut.ms, segments=len(cut.pieces)))
        outs.append(generate.AlbumOut(key=entry["key"], id=album.id, title=album.title, artist=album.artist,
                                      year=album.year, loot=album.loot, archived=album.archived, tracks=track_outs,
                                      cover=album.cover.read_bytes() if album.cover else None, media=album.media))
        audio_by_album.append((entry["key"], album.id, files))
        all_audio.update(files)
    outs.sort(key=lambda a: a.key)
    audio_by_album.sort()

    metadata = [{"key": a.key, "id": a.id, "title": a.title, "artist": a.artist, "year": a.year, "loot": a.loot,
                 "archived": a.archived, "media": a.media,
                 "tracks": [vars(t) for t in a.tracks]} for a in outs]
    placeholder = generate.public_files("", outs)
    version = package.version_of(placeholder, all_audio,
                                 {"albums": metadata, "engine": engine_version(), "generator": generate.VERSION})
    public = generate.public_files(version, outs)

    key_path = music / package.KEY_FILE
    if new_key and key_path.exists():
        key = package.new_key()
        package.write_key(music, key)
    else:
        key = package.read_key(music, create=True)
    folder = package.write_package(dist, version, engine_version(), key, public, audio_by_album)
    problems = package.verify(folder, key)
    if problems:
        raise SourceError("Il pacchetto appena scritto non torna: " + "; ".join(problems))
    lock.write(music, updated)
    size = sum(p.stat().st_size for p in folder.iterdir())
    return Report(version, folder, changes, len(albums), tracks, seconds, size)
