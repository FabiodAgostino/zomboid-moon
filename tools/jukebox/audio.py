"""Audio with ffmpeg and ffprobe: every track becomes OGG Vorbis pieces of SEGMENT_MS, each running OVERLAP_MS into
the next one, with a fade out at its end and a fade in at the start of the next (docs/jukebox/TECHNICAL_DESIGN.md,
«Il suono: pezzi da 10 s»). The game cannot start a sound file halfway: the pieces let whoever arrives join at the
next one.

The pieces of a track are kept in the music folder (.jukebox-cache/<impronta>): the same audio with the same settings
is never cut again, and the same file comes out every time (-fflags +bitexact, no metadata). After a build the
pieces no track uses any more go (prune_cache).

The pieces are mono. The game plays a sound file decoded whole into memory and never frees it until it closes
(fmod.fmod.FMODManager.loadSound: FMOD_System_CreateSound with FMOD_3D only, kept in fileToSoundMap; verified in the
42.21 jar): every minute of different music a player hears stays there, about 5 MB in mono, 10 in stereo. And the
jukebox is a sound in the world: from 2 tiles away the game plays it fully in 3D (FileSound, FMOD_Channel_Set3DLevel),
where a stereo sound comes from one point anyway.
"""

from __future__ import annotations

import hashlib
import json
import math
import shutil
import subprocess
import time
import wave
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from .source import SourceError

SEGMENT_MS = 10000
OVERLAP_MS = 250
RATE = 44100
CHANNELS = 1           # mono: see above
QUALITY = "5"          # libvorbis -q:a 5 (variable bit rate, good quality)
LOUDNESS = "loudnorm=I=-16:TP=-1.5:LRA=11"
MIN_MS = 5000
MAX_MS = 30 * 60 * 1000
CACHE = ".jukebox-cache"
SETTINGS = f"v1 seg={SEGMENT_MS} overlap={OVERLAP_MS} rate={RATE} ch={CHANNELS} q={QUALITY} {LOUDNESS}"


@dataclass
class Cut:
    ms: int
    pieces: list[Path]


def tools() -> tuple[str, str]:
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise SourceError("Mancano ffmpeg e ffprobe: installali (winget install Gyan.FFmpeg.Essentials) e riprova.")
    return ffmpeg, ffprobe


def run(args: list[str]) -> subprocess.CompletedProcess:
    result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0:
        tail = "\n".join(result.stderr.strip().splitlines()[-5:])
        raise SourceError(f"{Path(args[0]).name} non è riuscito:\n{tail}")
    return result


def rename(source: Path, target: Path, attempts: int = 20) -> None:
    """Rename a file or folder, trying again for a few seconds: on Windows an antivirus that is still reading the
    files just written makes the rename fail with «Accesso negato»."""
    for attempt in range(attempts):
        try:
            Path(source).replace(target)
            return
        except PermissionError:
            if attempt == attempts - 1:
                raise
            time.sleep(0.5)


def probe(path: Path) -> float:
    """The length in seconds of the first audio stream, or an error when ffprobe cannot read it."""
    _, ffprobe = tools()
    out = run([ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_type:format=duration",
               "-of", "json", str(path)]).stdout
    data = json.loads(out or "{}")
    if not data.get("streams"):
        raise SourceError(f"{path.name}: non trovo l'audio dentro.")
    try:
        seconds = float(data["format"]["duration"])
    except (KeyError, TypeError, ValueError) as e:
        raise SourceError(f"{path.name}: non riesco a leggerne la durata.") from e
    if not MIN_MS <= seconds * 1000 <= MAX_MS:
        raise SourceError(f"{path.name}: dura {seconds:.1f} s, mi aspetto fra {MIN_MS // 1000} s e {MAX_MS // 60000} minuti.")
    return seconds


def cache_key(source_sha: str) -> str:
    return hashlib.sha256(f"{source_sha} {SETTINGS}".encode()).hexdigest()[:24]


def segments(ms: int) -> int:
    return max(1, math.ceil(ms / SEGMENT_MS))


def _piece(ffmpeg: str, wav: Path, out: Path, k: int, count: int, ms: int) -> None:
    start = k * SEGMENT_MS
    last = k == count - 1
    length = (ms - start) if last else min(SEGMENT_MS + OVERLAP_MS, ms - start)
    fades = []
    if k > 0:
        fades.append(f"afade=t=in:st=0:d={OVERLAP_MS / 1000}")
    if not last:
        fades.append(f"afade=t=out:st={SEGMENT_MS / 1000}:d={OVERLAP_MS / 1000}")
    args = [ffmpeg, "-v", "error", "-y", "-ss", f"{start / 1000:.3f}", "-t", f"{length / 1000:.3f}", "-i", str(wav)]
    if fades:
        args += ["-af", ",".join(fades)]
    args += ["-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", "-c:a", "libvorbis",
             "-q:a", QUALITY, str(out)]
    run(args)


def cut(source: Path, source_sha: str, music: Path, workers: int = 4) -> Cut:
    """The pieces of one track, from the cache when they are there."""
    ffmpeg, _ = tools()
    folder = Path(music) / CACHE / cache_key(source_sha)
    meta = folder / "meta.json"
    if meta.exists():
        data = json.loads(meta.read_text(encoding="utf-8"))
        pieces = [folder / f"s{k:03d}.ogg" for k in range(data["segments"])]
        if data.get("settings") == SETTINGS and all(p.exists() for p in pieces):
            return Cut(ms=data["ms"], pieces=pieces)
    probe(source)
    tmp = folder.with_name(folder.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    wav = tmp / "track.wav"
    run([ffmpeg, "-v", "error", "-y", "-i", str(source), "-vn", "-af", LOUDNESS, "-ar", str(RATE), "-ac", str(CHANNELS),
         "-c:a", "pcm_s16le", "-map_metadata", "-1", "-fflags", "+bitexact", str(wav)])
    with wave.open(str(wav), "rb") as w:
        ms = int(w.getnframes() * 1000 // w.getframerate())
    if not MIN_MS <= ms <= MAX_MS:
        raise SourceError(f"{source.name}: dopo la conversione dura {ms} ms.")
    count = segments(ms)
    outs = [tmp / f"s{k:03d}.ogg" for k in range(count)]
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        for f in [pool.submit(_piece, ffmpeg, wav, outs[k], k, count, ms) for k in range(count)]:
            f.result()
    wav.unlink()
    (tmp / "meta.json").write_text(json.dumps({"ms": ms, "segments": count, "settings": SETTINGS}), encoding="utf-8")
    shutil.rmtree(folder, ignore_errors=True)
    rename(tmp, folder)
    return Cut(ms=ms, pieces=[folder / f"s{k:03d}.ogg" for k in range(count)])


def prune_cache(music: Path, used: set[str]) -> int:
    """Removes the cache's folders that no track of the last build uses (cache_key), and the leftovers of a cut that
    stopped halfway. Returns how many."""
    cache = Path(music) / CACHE
    if not cache.is_dir():
        return 0
    removed = 0
    for folder in cache.iterdir():
        if folder.is_dir() and folder.name not in used:
            shutil.rmtree(folder, ignore_errors=True)
            removed += 1
    return removed
