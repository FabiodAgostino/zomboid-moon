"""The builder of the CDs (tools/jukebox): checks of the music folder, the numbers that never change, the encryption,
and a real build with ffmpeg (skipped without it). Needs Python with Pillow, numpy and cryptography:

    python -m pytest -q tests/jukebox/test_builder.py
"""

from __future__ import annotations

import json
import shutil
import sys
import wave
from pathlib import Path

import pytest

pytest.importorskip("cryptography")
np = pytest.importorskip("numpy")

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.jukebox import audio, build, generate, lock, package, publish, source  # noqa: E402
from tools.jukebox.source import SourceError  # noqa: E402

FFMPEG = shutil.which("ffmpeg") and shutil.which("ffprobe")


def tone(path: Path, seconds: float, freq: float = 440.0) -> None:
    t = np.arange(int(seconds * 44100)) / 44100
    data = (0.3 * np.sin(2 * np.pi * freq * t) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(data.tobytes())


def album(music: Path, album_id: str, tracks: list[tuple[str, float]], **extra) -> Path:
    folder = music / "albums" / album_id
    folder.mkdir(parents=True, exist_ok=True)
    entries = []
    for n, (track_id, seconds) in enumerate(tracks):
        tone(folder / f"{track_id}.wav", seconds, 300 + 50 * n)
        entries.append({"id": track_id, "title": f"Brano {track_id} è", "file": f"{track_id}.wav"})
    meta = {"id": album_id, "title": f"Album {album_id}", "artist": "Prova", "tracks": entries, **extra}
    (folder / "album.json").write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    return folder


def edit(folder: Path, change) -> None:
    path = folder / "album.json"
    meta = json.loads(path.read_text(encoding="utf-8"))
    change(meta)
    path.write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")


# ------------------------------------------------------------------------------------------------ the music folder


@pytest.mark.parametrize("change, message", [
    (lambda m: m.update(id="Bad Id"), "«id»"),
    (lambda m: m.update(year=12), "«year»"),
    (lambda m: m.update(title="x" * 81), "lungo 81"),
    (lambda m: m.update(colour="red"), "campi che non conosco"),
    (lambda m: m["tracks"][0].update(file="../fuori.wav"), "nome di un file"),
    (lambda m: m["tracks"][0].update(file="manca.wav"), "non c'è"),
    (lambda m: m["tracks"][0].update(file="note.txt"), "formato"),
    (lambda m: m["tracks"].append(dict(m["tracks"][0])), "c'è già"),
    (lambda m: m.update(tracks=[]), "«tracks»"),
    (lambda m: m.update(lootWeight=11), "«lootWeight»"),
])
def test_a_bad_album_stops_everything_and_says_where(tmp_path, change, message):
    folder = album(tmp_path, "uno", [("a", 6)])
    (folder / "note.txt").write_text("x")
    edit(folder, change)
    with pytest.raises(SourceError) as e:
        source.load(tmp_path)
    assert message in str(e.value) and "albums/uno/album.json" in str(e.value)


def test_two_albums_with_the_same_id(tmp_path):
    album(tmp_path, "uno", [("a", 6)])
    other = album(tmp_path, "due", [("a", 6)])
    edit(other, lambda m: m.update(id="uno"))
    with pytest.raises(SourceError, match="sia in albums/"):
        source.load(tmp_path)


def test_a_link_out_of_the_album_is_refused(tmp_path):
    folder = album(tmp_path, "uno", [("a", 6)])
    outside = tmp_path / "fuori.wav"
    tone(outside, 6)
    try:
        (folder / "link.wav").symlink_to(outside)
    except OSError:
        pytest.skip("this Windows does not let us make links")
    edit(folder, lambda m: m["tracks"][0].update(file="link.wav"))
    with pytest.raises(SourceError, match="collegamento"):
        source.load(tmp_path)


# ------------------------------------------------------------------------------------------------ the lock


def albums_and_hashes(music):
    albums = source.load(music)
    return albums, {(a.id, t.id): lock.file_sha256(t.path) for a in albums for t in a.tracks}


def test_numbers_are_given_once_and_never_change(tmp_path):
    album(tmp_path, "uno", [("a", 6), ("b", 6)])
    albums, hashes = albums_and_hashes(tmp_path)
    first, changes = lock.update(lock.read(tmp_path), albums, set(), set(), hashes)
    assert changes.new_albums == ["uno"] and len(changes.new_tracks) == 2
    album(tmp_path, "aaa", [("x", 6)])                        # sorts before: still the next number
    albums, hashes = albums_and_hashes(tmp_path)
    second, changes = lock.update(first, albums, set(), set(), hashes)
    assert second["albums"]["uno"] == first["albums"]["uno"]
    assert second["albums"]["aaa"]["key"] == 2 and second["albums"]["aaa"]["tracks"]["x"]["key"] == 3
    assert changes.unchanged_tracks == ["uno/a", "uno/b"]


def test_changed_audio_or_something_gone_needs_an_explicit_word(tmp_path):
    folder = album(tmp_path, "uno", [("a", 6), ("b", 6)])
    albums, hashes = albums_and_hashes(tmp_path)
    first, _ = lock.update(lock.read(tmp_path), albums, set(), set(), hashes)
    tone(folder / "a.wav", 7)
    albums, hashes = albums_and_hashes(tmp_path)
    with pytest.raises(SourceError, match="--replace uno/a"):
        lock.update(first, albums, set(), set(), hashes)
    replaced, changes = lock.update(first, albums, {"uno/a"}, set(), hashes)
    assert changes.changed_tracks == ["uno/a"] and replaced["albums"]["uno"]["tracks"]["a"]["key"] == 1
    edit(folder, lambda m: m.update(tracks=m["tracks"][:1]))
    albums, hashes = albums_and_hashes(tmp_path)
    with pytest.raises(SourceError, match="--forget uno/b"):
        lock.update(replaced, albums, set(), set(), hashes)
    forgotten, changes = lock.update(replaced, albums, set(), {"uno/b"}, hashes)
    assert "b" not in forgotten["albums"]["uno"]["tracks"] and forgotten["nextTrack"] == 3   # never given again
    album(tmp_path, "due", [("z", 6)])
    shutil.rmtree(folder)
    albums, hashes = albums_and_hashes(tmp_path)
    with pytest.raises(SourceError, match="--forget uno"):
        lock.update(forgotten, albums, set(), set(), hashes)
    with pytest.raises(SourceError, match="non serve"):
        lock.update(forgotten, albums, {"due/z"}, {"uno"}, hashes)


# ------------------------------------------------------------------------------------------------ files


def test_lua_strings_are_ascii_with_utf8_bytes():
    assert generate.lua_string('Più "forte" \\ ok') == '"Pi\\195\\185 \\"forte\\" \\\\ ok"'
    assert generate.lua_string("è1") == '"\\195\\1681"'        # three digits: the 1 after stays a 1


def test_encryption_round_trip_same_file_every_time_wrong_key_refused():
    key = bytes(range(32))
    plain = package.make_zip({"b.ogg": b"2" * 100, "a.ogg": b"1" * 50})
    assert plain == package.make_zip({"a.ogg": b"1" * 50, "b.ogg": b"2" * 100})
    blob = package.encrypt(key, plain)
    assert blob == package.encrypt(key, plain) and blob[:4] == b"JBM1"
    assert package.encrypt(key, plain + b"x")[4:16] != blob[4:16]
    assert package.decrypt(key, blob) == plain
    with pytest.raises(Exception):
        package.decrypt(bytes(32), blob)
    assert package.read_zip(plain) == {"a.ogg": b"1" * 50, "b.ogg": b"2" * 100}


def test_the_key_is_made_once(tmp_path):
    key = package.read_key(tmp_path, create=True)
    assert package.read_key(tmp_path, create=False) == key and len(key) == 32
    (tmp_path / "jukebox.key").write_text("nope")
    with pytest.raises(ValueError):
        package.read_key(tmp_path, create=False)


# ------------------------------------------------------------------------------------------------ a real build


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_a_real_build_is_complete_reproducible_and_never_half_written(tmp_path):
    music = tmp_path / "music"
    album(music, "uno", [("a", 12.5), ("b", 6)], cover=None)
    album(music, "due", [("c", 21)], archived=False)
    edit(music / "albums" / "uno", lambda m: m.pop("cover"))
    dry = build.build(music, tmp_path / "dist", dry_run=True)
    assert dry.version is None and not (tmp_path / "dist").exists() and not (music / "jukebox.lock.json").exists()

    first = build.build(music, tmp_path / "dist")
    assert package.verify(first.folder, package.read_key(music, False)) == []
    manifest = json.loads((first.folder / "manifest.json").read_text(encoding="utf-8"))
    files = {f["path"] for f in manifest["catalog"]["files"]}
    assert "42/media/lua/shared/JukeboxMoon/CatalogData.lua" in files
    assert "42/media/textures/Item_JukeboxMoon_CD_2.png" in files
    pieces = {f["path"] for a in manifest["albums"] for f in a["files"]}
    # ids in order: «due» is album 1 (track c: 21 s, three pieces), «uno» album 2 (a: 12.5 s, two; b: 6 s, one)
    assert pieces == {"42/media/sound/jukeboxmoon/t1/s000.ogg", "42/media/sound/jukeboxmoon/t1/s001.ogg",
                      "42/media/sound/jukeboxmoon/t1/s002.ogg", "42/media/sound/jukeboxmoon/t2/s000.ogg",
                      "42/media/sound/jukeboxmoon/t2/s001.ogg", "42/media/sound/jukeboxmoon/t3/s000.ogg"}
    catalog = package.read_zip((first.folder / manifest["catalog"]["asset"]).read_bytes())
    lua = catalog["42/media/lua/shared/JukeboxMoon/CatalogData.lua"].decode("ascii")
    assert f'version = "{first.version}"' in lua and "ms = 12500, segments = 2" in lua
    sounds = catalog["42/media/scripts/JukeboxMoon_sounds.txt"].decode("ascii")
    assert sounds.count("    sound JukeboxMoon_T") == 6
    names = json.loads(catalog["42/media/lua/shared/Translate/IT/ItemName.json"])
    assert names == {"JukeboxMoon.CD_1": "CD: Album due", "JukeboxMoon.CD_2": "CD: Album uno"}  # ids sorted: due first

    shutil.rmtree(music / audio.CACHE)
    again = build.build(music, tmp_path / "dist2")
    assert again.version == first.version
    for f in first.folder.iterdir():
        assert (again.folder / f.name).read_bytes() == f.read_bytes(), f.name

    edit(music / "albums" / "due", lambda m: m.update(title="Album nuovo"))
    third = build.build(music, tmp_path / "dist")
    assert third.version != first.version
    assert {a["asset"] for a in json.loads((third.folder / "manifest.json").read_text())["albums"]} == \
           {a["asset"] for a in manifest["albums"]}                   # the audio did not change: same files

    edit(music / "albums" / "due", lambda m: m.update(year="x"))
    before = sorted(p.name for p in (tmp_path / "dist").iterdir())
    with pytest.raises(SourceError):
        build.build(music, tmp_path / "dist")
    assert sorted(p.name for p in (tmp_path / "dist").iterdir()) == before


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_install_puts_engine_catalogue_audio_and_key_on_this_computer(tmp_path):
    music = tmp_path / "music"
    album(music, "uno", [("a", 6)])
    report = build.build(music, tmp_path / "dist")
    zomboid = tmp_path / "Zomboid"
    publish.install(report.folder, music, zomboid, lambda s: None)
    mod = zomboid / "mods" / "JukeboxMoon"
    assert (mod / "42" / "mod.info").exists()
    assert (mod / "42" / "media" / "lua" / "server" / "JukeboxMoon" / "Server.lua").exists()
    assert (mod / "42" / "media" / "sound" / "jukeboxmoon" / "t1" / "s000.ogg").exists()
    key = package.read_key(music, False)
    assert (zomboid / "Lua" / "JukeboxMoon_server_key.txt").read_text() == f"{key.hex()}\n{package.key_id(key)}\n"


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_publish_to_the_server_without_audio(tmp_path):
    music = tmp_path / "music"
    album(music, "uno", [("a", 6)])
    report = build.build(music, tmp_path / "dist")
    lines = []
    publish.server(report.folder, music, "cirene", "mods dir", "lua", True, lines.append)
    assert any(line.startswith("(prova) scp -r -q") and "cirene:mods dir/JukeboxMoon.new" in line for line in lines)
    staged = tmp_path / "staged"
    publish.stage_mod(report.folder, staged, None)
    assert not (staged / "42" / "media" / "sound").exists()
    assert (staged / "42" / "media" / "scripts" / "JukeboxMoon_sounds.txt").exists()
