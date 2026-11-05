"""The demo music folder: two albums and three tracks of music made here, by numbers (no recording, nobody's work: free
to use as anyone likes), to try the builder, the launcher and the game without real music.

    python -m tools.jukebox demo --out <folder>
"""

from __future__ import annotations

import json
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

RATE = 44100

# (album id, title, artist, year, [(track id, title, seconds, bpm, root midi note, progression)])
ALBUMS = [
    ("demo-alba", "Alba su Moon", "Orchestra di prova", 1993, [
        ("risveglio", "Risveglio", 45, 96, 57, [0, 7, 9, 5]),
        ("strada-vuota", "Strada vuota", 25, 120, 55, [0, 5, 7, 3]),
    ]),
    ("demo-notte", "Notte al Rifugio", "I Sopravvissuti", 1994, [
        ("lanterne", "Lanterne è più", 35, 84, 52, [0, 3, 8, 7]),
    ]),
]


def _note(midi: float, seconds: float, volume: float, shape: str = "pluck") -> np.ndarray:
    t = np.arange(int(seconds * RATE)) / RATE
    f = 440.0 * 2 ** ((midi - 69) / 12)
    wave_ = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t) + 0.12 * np.sin(6 * np.pi * f * t)
    if shape == "pluck":
        env = np.exp(-t * 4.0)
    else:
        env = np.minimum(1, t * 8) * np.exp(-t * 0.8)
    return (volume * wave_ * env).astype(np.float32)


def _mix(buffer: np.ndarray, sound: np.ndarray, at: float) -> None:
    start = int(at * RATE)
    end = min(len(buffer), start + len(sound))
    if start < end:
        buffer[start:end] += sound[: end - start]


def track(seconds: float, bpm: int, root: int, progression: list[int], seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    beat = 60.0 / bpm
    left = np.zeros(int(seconds * RATE) + RATE, dtype=np.float32)
    right = np.zeros_like(left)
    bar = 0
    t = 0.0
    while t < seconds:
        chord = root + progression[bar % len(progression)]
        third = 3 if progression[bar % len(progression)] in (9, 3, 8) else 4
        notes = [chord, chord + third, chord + 7, chord + 12]
        _mix(left, _note(chord - 12, beat * 4, 0.25, "pad"), t)
        _mix(right, _note(chord - 12, beat * 4, 0.25, "pad"), t)
        for step in range(8):
            midi = notes[(step + bar) % 4] + (12 if step == 6 else 0)
            target = left if step % 2 == 0 else right
            _mix(target, _note(midi, beat * 1.5, 0.18), t + step * beat / 2)
        for step in range(4):
            hit = (rng.standard_normal(int(0.05 * RATE)) * np.exp(-np.arange(int(0.05 * RATE)) / 300)).astype(np.float32)
            _mix(left, 0.08 * hit, t + step * beat)
            _mix(right, 0.08 * hit, t + step * beat)
        t += beat * 4
        bar += 1
    n = int(seconds * RATE)
    stereo = np.stack([left[:n], right[:n]], axis=1)
    fade = int(1.5 * RATE)
    stereo[-fade:] *= np.linspace(1, 0, fade)[:, None]
    stereo /= max(1e-6, float(np.abs(stereo).max())) / 0.8
    return (stereo * 32767).astype("<i2")


def _cover(path: Path, seed: int, title: str) -> None:
    rng = np.random.default_rng(seed)
    image = Image.new("RGB", (512, 512))
    draw = ImageDraw.Draw(image)
    top, bottom = rng.integers(20, 120, 3), rng.integers(120, 230, 3)
    for y in range(512):
        c = tuple(int(top[i] + (bottom[i] - top[i]) * y / 511) for i in range(3))
        draw.line([(0, y), (511, y)], fill=c)
    draw.ellipse((150, 120, 362, 332), fill=(245, 240, 210))
    draw.text((24, 460), title, fill=(255, 255, 255))
    image.save(path, format="PNG")


def make(out: Path) -> Path:
    out = Path(out)
    for n, (album_id, title, artist, year, tracks) in enumerate(ALBUMS):
        folder = out / "albums" / album_id
        folder.mkdir(parents=True, exist_ok=True)
        entries = []
        for m, (track_id, track_title, seconds, bpm, root, progression) in enumerate(tracks, 1):
            name = f"{m:02d}-{track_id}.wav"
            data = track(seconds, bpm, root, progression, seed=n * 10 + m)
            with wave.open(str(folder / name), "wb") as w:
                w.setnchannels(2)
                w.setsampwidth(2)
                w.setframerate(RATE)
                w.writeframes(data.tobytes())
            entries.append({"id": track_id, "title": track_title, "file": name})
        _cover(folder / "cover.png", n, title)
        meta = {"id": album_id, "title": title, "artist": artist, "year": year, "cover": "cover.png",
                "lootWeight": 1.0, "tracks": entries}
        (folder / "album.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "LEGGIMI.txt").write_text(
        "Musica di prova di Jukebox (Moon), fatta con dei numeri da tools/jukebox/demo.py: libera, di nessuno.\n",
        encoding="utf-8")
    return out
