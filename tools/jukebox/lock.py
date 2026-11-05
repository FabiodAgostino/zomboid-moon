"""jukebox.lock.json: the numbers the builder gave to albums and tracks, and the audio each track had.

The numbers end up in the game's saves (item JukeboxMoon.CD_<album>, sounds JukeboxMoon_T<track>_S<piece>): they
never change and are never given again (FR-10). A new album or track takes the next number. The builder refuses,
unless the admin says so explicitly:
  - an album or a track of the lock that is no longer in the folder (``--forget album`` or ``--forget album/track``:
    CDs already in the saves would become unknown objects);
  - a track whose audio changed (``--replace album/track`` keeps its number; a new id gives it a new one).
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from .source import Album, SourceError

LOCK = "jukebox.lock.json"


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@dataclass
class Changes:
    new_albums: list[str] = field(default_factory=list)
    new_tracks: list[str] = field(default_factory=list)
    changed_tracks: list[str] = field(default_factory=list)      # replaced on purpose
    unchanged_tracks: list[str] = field(default_factory=list)
    forgotten: list[str] = field(default_factory=list)
    archived: list[str] = field(default_factory=list)


def read(source: Path) -> dict:
    path = Path(source) / LOCK
    if not path.exists():
        return {"format": 1, "nextAlbum": 1, "nextTrack": 1, "albums": {}}
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("format") != 1:
        raise SourceError(f"{LOCK}: formato {data.get('format')} sconosciuto.")
    return data


def write(source: Path, lock: dict) -> None:
    path = Path(source) / LOCK
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(lock, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def update(lock: dict, albums: list[Album], replace: set[str], forget: set[str],
           hashes: dict[tuple[str, str], str]) -> tuple[dict, Changes]:
    """The lock after this build (a new dict) and what changed. ``hashes``: (album, track) -> SHA-256 of its audio."""
    lock = json.loads(json.dumps(lock))
    changes = Changes()
    known = lock["albums"]
    present = {a.id for a in albums}
    for album_id in sorted(set(known) - present):
        if album_id in forget:
            changes.forgotten.append(album_id)
            del known[album_id]
        else:
            raise SourceError(
                f"L'album «{album_id}» era nel catalogo e ora non c'è: i suoi CD possono essere nei salvataggi. "
                f"Rimettilo (con \"archived\": true per non farlo più trovare), oppure, se sei sicuro, "
                f"--forget {album_id}.")
    for album in albums:
        entry = known.get(album.id)
        if entry is None:
            entry = {"key": lock["nextAlbum"], "tracks": {}}
            lock["nextAlbum"] += 1
            known[album.id] = entry
            changes.new_albums.append(album.id)
        if album.archived:
            changes.archived.append(album.id)
        tracks = entry["tracks"]
        here = {t.id for t in album.tracks}
        for track_id in sorted(set(tracks) - here):
            name = f"{album.id}/{track_id}"
            if name in forget:
                changes.forgotten.append(name)
                del tracks[track_id]
            else:
                raise SourceError(
                    f"Il brano «{name}» era nel catalogo e ora non c'è: chi ha quel CD lo cerca ancora. "
                    f"Rimettilo, oppure, se sei sicuro, --forget {name}.")
        for track in album.tracks:
            name = f"{album.id}/{track.id}"
            digest = hashes[(album.id, track.id)]
            known_track = tracks.get(track.id)
            if known_track is None:
                tracks[track.id] = {"key": lock["nextTrack"], "source": digest}
                lock["nextTrack"] += 1
                changes.new_tracks.append(name)
            elif known_track["source"] != digest:
                if name not in replace:
                    raise SourceError(
                        f"L'audio di «{name}» è cambiato. Se è lo stesso brano rifatto, --replace {name} (tiene il "
                        f"suo numero); se è un altro brano, dagli un id nuovo.")
                known_track["source"] = digest
                changes.changed_tracks.append(name)
            else:
                changes.unchanged_tracks.append(name)
    unused = sorted((replace | forget) - set(changes.changed_tracks) - set(changes.forgotten))
    if unused:
        raise SourceError(f"--replace o --forget per qualcosa che non c'è o non serve: {', '.join(unused)}.")
    return lock, changes
