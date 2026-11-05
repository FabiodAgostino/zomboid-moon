"""The game's CDs with the audio of Radio Voices (Workshop 3828360540, by Espaidi): one album of the music folder for
every CD of the game that Radio Voices sings or reads, so the game's discs (Base.Disc_Retail) play in the jukebox.

    python -m tools.jukebox import-radiovoices --radiovoices <RadioVoices> --out <music folder> [--game <ProjectZomboid>]

How a CD becomes an album (docs/jukebox/TECHNICAL_DESIGN.md, «I CD del gioco»):
  - the game's CDs are recorded media of category "CDs" (media/lua/shared/RecordedMedia/recorded_media.lua): title,
    author, "Released ... 1993" and the lines shown while it plays (English texts in Translate/EN/Recorded_Media.json);
  - Radio Voices keys every line by its normalized English text (RadioVoices.normalize). Its songs
    (RadioVoices.songs) list the lines they sing and have the whole song in one sound (starts[1], RV_s_<id>_0);
  - a CD's tracks are the songs that cover its lines, the one covering most first (two versions of a song share their
    first lines), in the order they start; a CD with no song but read lines (audiobooks, Bible, history) becomes one
    track: its lines' clips one after the other, with a short pause;
  - the album's id is "cd-" and the first 8 characters of the recording's id; "vanillaMedia" is the recording.
The audio stays in the admin's music folder: never in this repository (the command refuses to write inside it).
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import audio
from .build import REPO
from .source import SourceError

STEAM_GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid")
PAUSE = 0.6          # seconds between two read lines
MIN_SONG_LINES = 3   # a song is on a CD when it sings at least this many of its lines
MIN_READ = 0.7       # a read CD needs a clip for at least this share of its lines
MANAGED = "cd-"      # the albums this command writes, and rewrites


def normalize(text: str) -> str:
    """RadioVoices.normalize: tags out, ASCII letters and digits in lower case, anything else one space."""
    text = re.sub(r"<[^>]*>", " ", text)
    out: list[str] = []
    pending = False
    for ch in text:
        b = ord(ch)
        if 65 <= b <= 90:
            ch, b = chr(b + 32), b + 32
        if 97 <= b <= 122 or 48 <= b <= 57:
            if pending and out:
                out.append(" ")
            pending = False
            out.append(ch)
        else:
            pending = True
    return "".join(out)


def clean(text: str) -> str:
    """A lyric line as a title: no [img=music], no dots or spaces around it."""
    text = re.sub(r"\[img=[^\]]*\]", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" .,;:-*")
    return text[:80]


@dataclass
class GameCD:
    media: str
    title: str
    author: str
    year: int | None
    lines: list[str]


@dataclass
class Song:
    sound: str
    seconds: float
    keys: set[str]


@dataclass
class Plan:
    cd: GameCD
    songs: list[tuple[str, str]] = field(default_factory=list)      # (song id, title)
    read: list[str] = field(default_factory=list)                    # clip sounds, in order


def game_cds(game: Path) -> list[GameCD]:
    shared = Path(game) / "media" / "lua" / "shared"
    source = (shared / "RecordedMedia" / "recorded_media.lua").read_text(encoding="utf-8")
    texts = json.loads((shared / "Translate" / "EN" / "Recorded_Media.json").read_text(encoding="utf-8"))
    cds = []
    for m in re.finditer(r'RecMedia\["([^"]+)"\] = \{(.*?)\n\}', source, re.S):
        body = m.group(2)
        if 'category = "CDs"' not in body:
            continue

        def field_(name: str) -> str:
            found = re.search(rf'\b{name} = "([^"]*)"', body)
            return texts.get(found.group(1), "") if found else ""

        year = re.search(r"\b(1[89]\d\d|20\d\d)\b", field_("extra"))
        cds.append(GameCD(media=m.group(1), title=field_("title").strip(), author=field_("author").strip(),
                          year=int(year.group(1)) if year else None,
                          lines=[texts.get(k, "") for k in re.findall(r'\{ text = "([^"]+)"', body)]))
    if not cds:
        raise SourceError(f"{game}: non trovo i CD del gioco (recorded_media.lua).")
    return cds


def radio_voices(mod: Path) -> tuple[dict[str, tuple[str, float]], dict[str, Song], dict[str, Path]]:
    """clips (line -> sound, seconds), songs (id -> Song) and every sound's file, from the mod's 42 folder."""
    data_file = mod / "media" / "lua" / "shared" / "RadioVoices" / "RadioVoiceData.lua"
    data = data_file.read_text(encoding="utf-8")
    end = data.index("RadioVoices.clipKind = {")
    clips = {k: (sound, float(d)) for k, sound, d in
             re.findall(r'^    \["([^"]*)"\] = \{"(RV_r_[0-9a-f]+)", ([\d.]+)\},', data[:end], re.M)}
    start, end = data.index("RadioVoices.songs = {"), data.index("RadioVoices.songLine = {")
    songs = {}
    for m in re.finditer(r'^    \["(s_[0-9a-f]+)"\] = \{(.*?)^    \},', data[start:end], re.M | re.S):
        body = m.group(2)
        first = re.search(r'starts = \{\[1\] = \{"(RV_s_[0-9a-f]+_0)", ([\d.]+), ([\d.]+)\}', body)
        keys = re.search(r"keys = \{(.*?)\},\n", body, re.S)
        if first and keys:
            songs[m.group(1)] = Song(sound=first.group(1), seconds=float(first.group(2)),
                                     keys=set(re.findall(r'"([^"]*)"', keys.group(1))))
    files = {}
    for script in (mod / "media" / "scripts").glob("*.txt"):
        for name, file in re.findall(r"sound (RV_\w+)\s*\{.*?file = (media/sound/[\w/.-]+),", script.read_text(
                encoding="utf-8"), re.S):
            files[name] = mod / file
    if not clips or not songs:
        raise SourceError(f"{data_file}: non riconosco i dati di Radio Voices.")
    return clips, songs, files


def plan(cd: GameCD, clips: dict[str, tuple[str, float]], songs: dict[str, Song]) -> Plan:
    lines = [normalize(t) for t in cd.lines]
    result = Plan(cd)
    covers = {sid: [i for i, n in enumerate(lines) if n in s.keys] for sid, s in songs.items()}
    left = {i for c in covers.values() for i in c}
    chosen = []
    while left:
        sid, best = max(((sid, [i for i in c if i in left]) for sid, c in covers.items()),
                        key=lambda kv: (len(kv[1]), kv[0]))
        if len(best) < MIN_SONG_LINES:
            break
        chosen.append((min(best), sid))
        left -= set(covers[sid])
    sung = {i for _, sid in chosen for i in covers[sid]}
    if chosen and len(sung) >= len(lines) / 2:
        for first, sid in sorted(chosen):
            result.songs.append((sid, clean(cd.lines[first]) or cd.title))
        return result
    read = [clips[n][0] for n in lines if n in clips]
    if lines and len(read) >= MIN_READ * len(lines):
        result.read = read
    return result


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "brano"


def import_cds(radiovoices: Path, out: Path, game: Path = STEAM_GAME, log=print) -> list[Plan]:
    out = Path(out).resolve()
    if out == REPO or REPO in out.parents:
        raise SourceError("La musica non va mai nel repo: scegli una cartella fuori da zomboid-moon.")
    radiovoices = Path(radiovoices)
    mod = next((p for p in [radiovoices, radiovoices / "42", radiovoices / "mods" / "RadioVoices" / "42"]
                if (p / "media" / "lua" / "shared" / "RadioVoices").is_dir()), None)
    if mod is None:
        raise SourceError(f"{radiovoices}: non è la mod Radio Voices (manca media/lua/shared/RadioVoices).")
    ffmpeg, _ = audio.tools()
    clips, songs, files = radio_voices(mod)
    plans = [plan(cd, clips, songs) for cd in game_cds(game)]
    albums_dir = out / "albums"
    albums_dir.mkdir(parents=True, exist_ok=True)
    for old in albums_dir.glob(MANAGED + "*"):
        shutil.rmtree(old)
    for p in plans:
        cd = p.cd
        if not p.songs and not p.read:
            log(f"  senza audio in Radio Voices: {cd.author} - {cd.title}")
            continue
        folder = albums_dir / (MANAGED + cd.media[:8])
        folder.mkdir()
        tracks = []
        for sid, title in p.songs:
            shutil.copyfile(files[songs[sid].sound], folder / f"{sid}.ogg")
            tracks.append({"id": sid.replace("_", "-"), "title": title, "file": f"{sid}.ogg"})
        if p.read:
            _read_track(ffmpeg, [files[s] for s in p.read], folder / "lettura.wav")
            tracks.append({"id": "lettura", "title": cd.title, "file": "lettura.wav"})
        meta = {"id": MANAGED + cd.media[:8], "title": cd.title[:80] or "CD", "artist": cd.author[:80],
                "vanillaMedia": cd.media, "lootWeight": 0.0, "tracks": tracks}
        if cd.year:
            meta["year"] = cd.year
        (folder / "album.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "LEGGIMI-radio-voices.txt").write_text(
        "Le cartelle albums/cd-* sono i CD del gioco con l'audio di Radio Voices (Steam Workshop 3828360540, di "
        "Espaidi): le riscrive python -m tools.jukebox import-radiovoices. Musica e voci sono dei loro autori; il "
        "permesso di usarle lo chiede l'admin. Mai in git.\n", encoding="utf-8")
    return plans


def _read_track(ffmpeg: str, clips: list[Path], out: Path) -> None:
    """The read lines one after the other with PAUSE seconds between them, as one WAV."""
    args = [ffmpeg, "-v", "error", "-y"]
    for clip in clips:
        args += ["-i", str(clip)]
    pads = ";".join(f"[{i}:a]aresample=44100,aformat=channel_layouts=stereo,apad=pad_dur={PAUSE}[p{i}]"
                    for i in range(len(clips)))
    chain = pads + ";" + "".join(f"[p{i}]" for i in range(len(clips))) + f"concat=n={len(clips)}:v=0:a=1[out]"
    args += ["-filter_complex", chain, "-map", "[out]", "-c:a", "pcm_s16le", str(out)]
    result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0:
        raise SourceError(f"ffmpeg non riesce a mettere insieme la lettura {out.parent.name}: {result.stderr[-500:]}")
