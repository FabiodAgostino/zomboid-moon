"""The admin's music folder: catalogue.json (optional) and albums/<folder>/album.json with the audio and the cover.

Everything a build reads is checked here first, and a problem stops the build before anything is written: missing
files, files outside the album's folder (``../``, links), unsupported formats, duplicate ids, names too long.

    music/
      albums/
        estate-1993/
          album.json   {"id": "estate-1993", "title": "Estate 1993", "artist": "Artisti vari", "year": 1993,
                        "cover": "cover.png", "lootWeight": 1.0,
                        "tracks": [{"id": "traccia-01", "title": "Primo brano", "artist": "Artista A", "file": "01.mp3"}]}
          cover.png
          01.mp3
      jukebox.lock.json   written by the builder: the numbers given to albums and tracks (never change them)
      jukebox.key         written by the builder: the key of the music (secret)
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
MEDIA = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
AUDIO = {".mp3", ".flac", ".ogg", ".wav", ".m4a", ".opus", ".aac"}
COVER = {".png", ".jpg", ".jpeg"}
MAX_TITLE = 80
MAX_TRACKS = 60
MAX_AUDIO_BYTES = 300 * 1024 * 1024
MAX_COVER_BYTES = 20 * 1024 * 1024


class SourceError(Exception):
    """A problem of the music folder: the message says what and where, in Italian, for the admin."""


@dataclass
class Track:
    id: str
    title: str
    artist: str
    path: Path
    n: int


@dataclass
class Album:
    id: str
    title: str
    artist: str
    year: int | None
    loot: float
    archived: bool
    folder: Path
    cover: Path | None
    media: str | None = None      # a CD of the game (its recording's id): no new item, the game's disc plays it
    tracks: list[Track] = field(default_factory=list)


def _text(value, what: str, where: str, required: bool = True) -> str:
    if value is None and not required:
        return ""
    if not isinstance(value, str) or (required and not value.strip()):
        raise SourceError(f"{where}: «{what}» deve essere un testo{' non vuoto' if required else ''}.")
    value = value.strip()
    if len(value) > MAX_TITLE:
        raise SourceError(f"{where}: «{what}» è lungo {len(value)} caratteri, al massimo {MAX_TITLE}.")
    if any(ord(c) < 32 for c in value):
        raise SourceError(f"{where}: «{what}» contiene caratteri di controllo.")
    return value


def _inside(folder: Path, name, what: str, where: str, kinds: set[str], max_bytes: int) -> Path:
    """A file named in album.json: a plain name in the album's folder, really there, of a known kind."""
    if not isinstance(name, str) or not name or name in {".", ".."} or "/" in name or "\\" in name or ":" in name:
        raise SourceError(f"{where}: «{what}» deve essere il nome di un file nella cartella dell'album, non «{name}».")
    path = folder / name
    if path.suffix.lower() not in kinds:
        raise SourceError(f"{where}: {name} non è un formato che conosco ({', '.join(sorted(kinds))}).")
    if path.is_symlink() or not path.is_file():
        raise SourceError(f"{where}: {name} non c'è (o è un collegamento).")
    real = path.resolve()
    if real.parent != folder.resolve():
        raise SourceError(f"{where}: {name} esce dalla cartella dell'album.")
    size = real.stat().st_size
    if size == 0 or size > max_bytes:
        raise SourceError(f"{where}: {name} pesa {size} byte, mi aspetto fra 1 e {max_bytes}.")
    return real


def load_album(folder: Path) -> Album:
    where = f"albums/{folder.name}/album.json"
    meta = folder / "album.json"
    if not meta.is_file():
        raise SourceError(f"{where}: manca.")
    try:
        data = json.loads(meta.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise SourceError(f"{where}: non è un JSON valido in UTF-8 ({e}).") from e
    if not isinstance(data, dict):
        raise SourceError(f"{where}: deve essere un oggetto JSON.")
    unknown = set(data) - {"id", "title", "artist", "year", "cover", "lootWeight", "archived", "tracks", "vanillaMedia"}
    if unknown:
        raise SourceError(f"{where}: campi che non conosco: {', '.join(sorted(unknown))}.")
    album_id = data.get("id")
    if not isinstance(album_id, str) or not ID.match(album_id):
        raise SourceError(f"{where}: «id» deve essere fatto di lettere minuscole, cifre e trattini (al massimo 40).")
    year = data.get("year")
    if year is not None and (not isinstance(year, int) or isinstance(year, bool) or not 1800 <= year <= 2100):
        raise SourceError(f"{where}: «year» deve essere un anno, come 1993.")
    loot = data.get("lootWeight", 1.0)
    if isinstance(loot, bool) or not isinstance(loot, (int, float)) or not 0 <= loot <= 10:
        raise SourceError(f"{where}: «lootWeight» deve essere un numero da 0 a 10.")
    archived = data.get("archived", False)
    if not isinstance(archived, bool):
        raise SourceError(f"{where}: «archived» deve essere true o false.")
    media = data.get("vanillaMedia")
    if media is not None and (not isinstance(media, str) or not MEDIA.match(media)):
        raise SourceError(f"{where}: «vanillaMedia» deve essere l'id di una registrazione del gioco "
                          f"(come 89108e07-fc70-4eec-a267-790d6f4b9831).")
    cover = None
    if data.get("cover") is not None:
        cover = _inside(folder, data["cover"], "cover", where, COVER, MAX_COVER_BYTES)
    album = Album(
        id=album_id,
        title=_text(data.get("title"), "title", where),
        artist=_text(data.get("artist"), "artist", where, required=False),
        year=year,
        loot=float(loot),
        archived=archived,
        folder=folder,
        cover=cover,
        media=media,
    )
    tracks = data.get("tracks")
    if not isinstance(tracks, list) or not 1 <= len(tracks) <= MAX_TRACKS:
        raise SourceError(f"{where}: «tracks» deve essere una lista da 1 a {MAX_TRACKS} brani.")
    seen: set[str] = set()
    for n, t in enumerate(tracks, 1):
        at = f"{where}, brano {n}"
        if not isinstance(t, dict):
            raise SourceError(f"{at}: deve essere un oggetto JSON.")
        unknown = set(t) - {"id", "title", "artist", "file"}
        if unknown:
            raise SourceError(f"{at}: campi che non conosco: {', '.join(sorted(unknown))}.")
        track_id = t.get("id")
        if not isinstance(track_id, str) or not ID.match(track_id):
            raise SourceError(f"{at}: «id» deve essere fatto di lettere minuscole, cifre e trattini (al massimo 40).")
        if track_id in seen:
            raise SourceError(f"{at}: l'id «{track_id}» c'è già in questo album.")
        seen.add(track_id)
        album.tracks.append(Track(
            id=track_id,
            title=_text(t.get("title"), "title", at),
            artist=_text(t.get("artist"), "artist", at, required=False),
            path=_inside(folder, t.get("file"), "file", at, AUDIO, MAX_AUDIO_BYTES),
            n=n,
        ))
    return album


def load(source: Path) -> list[Album]:
    """Every album of the music folder, in the order of their ids (the same on every computer)."""
    source = Path(source)
    albums_dir = source / "albums"
    if not albums_dir.is_dir():
        raise SourceError(f"{source}: manca la cartella «albums».")
    albums = []
    for folder in sorted(albums_dir.iterdir(), key=lambda p: p.name):
        if folder.name.startswith(".") or not folder.is_dir():
            continue
        if folder.is_symlink():
            raise SourceError(f"albums/{folder.name}: è un collegamento, non una cartella.")
        albums.append(load_album(folder))
    if not albums:
        raise SourceError(f"{source}: in «albums» non c'è nessun album.")
    ids: dict[str, str] = {}
    media: dict[str, str] = {}
    for album in albums:
        if album.id in ids:
            raise SourceError(f"L'id «{album.id}» è sia in albums/{ids[album.id]} sia in albums/{album.folder.name}.")
        ids[album.id] = album.folder.name
        if album.media:
            if album.media in media:
                raise SourceError(f"Il CD del gioco {album.media} è sia in albums/{media[album.media]} sia in "
                                  f"albums/{album.folder.name}.")
            media[album.media] = album.folder.name
    return sorted(albums, key=lambda a: a.id)
