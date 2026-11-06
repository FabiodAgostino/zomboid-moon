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
    piece = next((music / audio.CACHE).glob("*/s000.ogg"))
    probe = audio.run([shutil.which("ffprobe"), "-v", "error", "-show_entries", "stream=channels,sample_rate",
                       "-of", "json", str(piece)]).stdout
    assert json.loads(probe)["streams"][0] == {"sample_rate": "44100", "channels": 1}   # mono: half the game's memory
    assert not (tmp_path / "dist" / ".staging").exists()
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
    publish.install(report.folder, music, zomboid, lambda s: None)          # again, over the one there
    assert [p.name for p in (zomboid / "mods").iterdir()] == ["JukeboxMoon"]
    assert not (zomboid / publish.ASIDE).exists()


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_publish_to_the_server_without_audio(tmp_path):
    music = tmp_path / "music"
    album(music, "uno", [("a", 6)])
    report = build.build(music, tmp_path / "dist")
    lines = []
    publish.server(report.folder, music, "cirene", "srv/Zomboid/mods dir", "lua", True, lines.append)
    # the new copy and the one before stay out of mods: the game would find two mods with the same id
    assert any(line.startswith("(prova) scp -r -q") and "cirene:srv/Zomboid/JukeboxMoon-publish/new" in line
               for line in lines)
    assert not any("JukeboxMoon.new" in line or "JukeboxMoon.old" in line for line in lines)
    staged = tmp_path / "staged"
    publish.stage_mod(report.folder, staged, None)
    assert not (staged / "42" / "media" / "sound").exists()
    assert (staged / "42" / "media" / "scripts" / "JukeboxMoon_sounds.txt").exists()


# ------------------------------------------------------------------------------------------------ the game's CDs

MEDIA = "89108e07-fc70-4eec-a267-790d6f4b9831"


def test_a_game_cd_album_needs_a_recording_id_once(tmp_path):
    folder = album(tmp_path, "cd-uno", [("a", 6)], vanillaMedia="not-an-id")
    with pytest.raises(SourceError, match="vanillaMedia"):
        source.load(tmp_path)
    edit(folder, lambda m: m.update(vanillaMedia=MEDIA))
    album(tmp_path, "cd-due", [("b", 6)], vanillaMedia=MEDIA)
    with pytest.raises(SourceError, match=MEDIA):
        source.load(tmp_path)


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_a_game_cd_album_has_no_new_item(tmp_path):
    music = tmp_path / "music"
    album(music, "cd-uno", [("a", 6)], vanillaMedia=MEDIA)
    album(music, "nostro", [("b", 6)])
    report = build.build(music, tmp_path / "dist")
    manifest = json.loads((report.folder / "manifest.json").read_text(encoding="utf-8"))
    catalog = package.read_zip((report.folder / manifest["catalog"]["asset"]).read_bytes())
    lua = catalog["42/media/lua/shared/JukeboxMoon/CatalogData.lua"].decode("ascii")
    assert f'id = "cd-uno", media = "{MEDIA}",' in lua and 'id = "nostro", item = "JukeboxMoon.CD_2",' in lua
    assert "CD_1" not in catalog["42/media/scripts/JukeboxMoon_catalog.txt"].decode("ascii")
    assert "42/media/textures/Item_JukeboxMoon_CD_1.png" not in catalog
    assert "42/media/textures/JukeboxMoon/Cover_1.png" in catalog
    assert json.loads(catalog["42/media/lua/shared/Translate/IT/ItemName.json"]) == {"JukeboxMoon.CD_2": "CD: Album nostro"}


def fake_game(root: Path) -> Path:
    shared = root / "media" / "lua" / "shared"
    (shared / "RecordedMedia").mkdir(parents=True)
    (shared / "Translate" / "EN").mkdir(parents=True)
    media = """-- Category: CDs
RecMedia["%s"] = {
\titemDisplayName = "RM_d",
\ttitle = "RM_t1",
\tsubtitle = nil,
\tauthor = "RM_a1",
\textra = "RM_e1",
\tspawning = 0,
\tcategory = "CDs",
\tlines = {
\t\t{ text = "RM_l1", r = 0, g = 0, b = 0, codes = "BOR-1" },
\t\t{ text = "RM_l2", r = 0, g = 0, b = 0, codes = "BOR-1" },
\t\t{ text = "RM_l3", r = 0, g = 0, b = 0, codes = "BOR-1" },
\t},
};
RecMedia["11111111-2222-3333-4444-555555555555"] = {
\titemDisplayName = "RM_d",
\ttitle = "RM_t2",
\tsubtitle = nil,
\tauthor = "RM_a2",
\textra = nil,
\tspawning = 0,
\tcategory = "CDs",
\tlines = {
\t\t{ text = "RM_r1", r = 0, g = 0, b = 0, codes = "BOR-1" },
\t\t{ text = "RM_r2", r = 0, g = 0, b = 0, codes = "BOR-1" },
\t},
};
RecMedia["99999999-2222-3333-4444-555555555555"] = {
\titemDisplayName = "RM_d",
\ttitle = "RM_t3",
\tsubtitle = nil,
\tauthor = "RM_a2",
\textra = nil,
\tspawning = 0,
\tcategory = "CDs",
\tlines = {
\t\t{ text = "RM_x1", r = 0, g = 0, b = 0, codes = "BOR-1" },
\t},
};
""" % MEDIA
    (shared / "RecordedMedia" / "recorded_media.lua").write_text(media, encoding="utf-8")
    texts = {"RM_t1": "Your Smile. Your Kiss.", "RM_a1": "Every Reason", "RM_e1": "Released February 1993. Potassium.",
             "RM_l1": "[img=music] I don't know... [img=music]", "RM_l2": "[img=music] if she loves me [img=music]",
             "RM_l3": "[img=music] Your smile, your kiss! [img=music]",
             "RM_t2": "Walden - Audio Book", "RM_a2": "Henry David Thoreau", "RM_r1": "I went to the woods.",
             "RM_r2": "Because I wished to live deliberately.", "RM_t3": "Silent", "RM_x1": "Nothing here."}
    (shared / "Translate" / "EN" / "Recorded_Media.json").write_text(json.dumps(texts), encoding="utf-8")
    return root


def fake_radio_voices(root: Path) -> Path:
    mod = root / "mods" / "RadioVoices" / "42"
    data = mod / "media" / "lua" / "shared" / "RadioVoices"
    data.mkdir(parents=True)
    (mod / "media" / "scripts").mkdir(parents=True)
    sound = mod / "media" / "sound" / "radiovoices"
    sound.mkdir(parents=True)
    lua = """RadioVoices = RadioVoices or {}
RadioVoices.clips = {
    ["i went to the woods"] = {"RV_r_aaaa000001", 6.000},
    ["because i wished to live deliberately"] = {"RV_r_aaaa000002", 6.000},
}
RadioVoices.clipKind = {
}
RadioVoices.songs = {
    ["s_0000beef"] = {
        keys = {"img music i don t know img music", "img music if she loves me img music", "img music your smile your kiss img music"},
        t = {1.0, 2.0, 3.0},
        stop = 7.0,
        starts = {[1] = {"RV_s_0000beef_0", 7.000, 0.000}},
    },
    ["s_0000cafe"] = {
        keys = {"img music i don t know img music"},
        t = {1.0},
        stop = 6.0,
        starts = {[1] = {"RV_s_0000cafe_0", 6.000, 0.000}},
    },
}
RadioVoices.songLine = {
}
"""
    (data / "RadioVoiceData.lua").write_text(lua, encoding="utf-8")
    script = "module Base\n{\n"
    for name in ("r_aaaa000001", "r_aaaa000002", "s_0000beef_0", "s_0000cafe_0"):
        script += f"    sound RV_{name}\n    {{\n        clip\n        {{\n            file = media/sound/radiovoices/{name}.ogg,\n        }}\n    }}\n"
        wav = sound / f"{name}.wav"
        tone(wav, 7 if name.startswith("s_") else 6)
        audio.run([shutil.which("ffmpeg"), "-v", "error", "-y", "-i", str(wav), "-c:a", "libvorbis", str(sound / f"{name}.ogg")])
        wav.unlink()
    (mod / "media" / "scripts" / "radiovoices_sounds.txt").write_text(script + "}\n", encoding="utf-8")
    return root


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_the_games_cds_from_radio_voices(tmp_path):
    from tools.jukebox import radiovoices
    game = fake_game(tmp_path / "game")
    rv = fake_radio_voices(tmp_path / "rv")
    music = tmp_path / "music"
    album(music, "nostro", [("b", 6)])                              # the admin's own albums are never touched,
    album(music, "cd-natale", [("n", 6)])                           # even when their folder starts with cd-
    (music / "albums" / "cd-old").mkdir()                            # an old import: rewritten
    (music / "albums" / "cd-old" / radiovoices.MARKER).write_text("x")
    plans = radiovoices.import_cds(rv, music, game, lambda s: None)
    assert (music / "albums" / "cd-natale" / "album.json").exists()
    assert (music / "albums" / "cd-89108e07" / radiovoices.MARKER).exists()
    assert not (music / ".radiovoices-import").exists()
    assert [len(p.songs) for p in plans] == [1, 0, 0] and [bool(p.read) for p in plans] == [False, True, False]
    sung = json.loads((music / "albums" / "cd-89108e07" / "album.json").read_text(encoding="utf-8"))
    assert sung["vanillaMedia"] == MEDIA and sung["artist"] == "Every Reason" and sung["year"] == 1993
    assert sung["tracks"] == [{"id": "s-0000beef", "title": "I don't know", "file": "s_0000beef.ogg"}]  # most lines
    read = json.loads((music / "albums" / "cd-11111111" / "album.json").read_text(encoding="utf-8"))
    assert read["tracks"] == [{"id": "lettura", "title": "Walden - Audio Book", "file": "lettura.wav"}]
    assert audio.probe(music / "albums" / "cd-11111111" / "lettura.wav") == pytest.approx(2 * (6 + radiovoices.PAUSE), abs=0.1)
    assert not (music / "albums" / "cd-99999999").exists() and not (music / "albums" / "cd-old").exists()
    assert (music / "albums" / "nostro" / "album.json").exists()
    albums, _ = build.validate(music)
    assert {a.id for a in albums} == {"cd-89108e07", "cd-11111111", "nostro", "cd-natale"}
    with pytest.raises(SourceError, match="mai nel repo"):
        radiovoices.import_cds(rv, ROOT / "dist-prova", game, lambda s: None)

    # an import made before the marker existed is still recognised and rewritten
    (music / "albums" / "cd-89108e07" / radiovoices.MARKER).unlink()
    radiovoices.import_cds(rv, music, game, lambda s: None)
    assert (music / "albums" / "cd-89108e07" / radiovoices.MARKER).exists()
    # a folder of the admin's with the name the import wants: refused, nothing changed
    shutil.rmtree(music / "albums" / "cd-11111111")
    album(music, "cd-11111111", [("m", 6)])
    with pytest.raises(SourceError, match="non l'ha fatta import-radiovoices"):
        radiovoices.import_cds(rv, music, game, lambda s: None)
    assert json.loads((music / "albums" / "cd-11111111" / "album.json").read_text(encoding="utf-8"))["tracks"][0]["id"] == "m"
    assert (music / "albums" / "cd-89108e07" / "album.json").exists() and not (music / ".radiovoices-import").exists()


@pytest.mark.parametrize("unique, message", [
    ({"from": "runner", "oneIn": 0}, "«unique»"),
    ({"from": "chest", "oneIn": 300}, "«unique»"),
    ({"oneIn": 300}, "«unique»"),
    ({}, "«unique»"),
    ({"from": "runner", "oneIn": "300"}, "«unique»"),
    ({"from": "runner", "oneIn": 300, "extra": 1}, "«unique»"),
    ("runner", "«unique»"),
])
def test_a_bad_unique_cd_is_refused(tmp_path, unique, message):
    album(tmp_path, "uno", [("a", 6)], unique=unique)
    with pytest.raises(SourceError, match=message):
        source.load(tmp_path)


def test_a_unique_cd_reaches_the_catalogue_with_its_names_ready_for_json(tmp_path):
    album(tmp_path, "uno", [("a", 6)], unique={"from": "runner", "oneIn": 300})
    assert source.load(tmp_path)[0].unique == {"from": "runner", "oneIn": 300}   # an old album.json: kept as it was
    album(tmp_path, "uno", [("a", 6)], unique={"from": "runner"})              # since 6 November 2026: no "oneIn"
    assert source.load(tmp_path)[0].unique == {"from": "runner"}
    album(tmp_path, "cd-uno", [("b", 6)], vanillaMedia=MEDIA, unique={"from": "runner", "oneIn": 3})
    with pytest.raises(SourceError, match="non può essere unico"):
        source.load(tmp_path)
    out = generate.AlbumOut(key=7, id="uno", title="Più bello", artist='La "banda"', year=None, loot=1.0,
                            archived=False, tracks=[], cover=None, unique={"from": "runner", "oneIn": 300})
    lua = generate.catalog_lua("v", [out])
    assert ('unique = { from = "runner", oneIn = 300, jsonName = "CD: Pi\\\\u00f9 bello", '
            'jsonArtist = "La \\\\\\"banda\\\\\\"" },') in lua
    assert lua.isascii()
    out.unique = {"from": "runner"}                                  # the mod no longer reads it: none written
    assert ('unique = { from = "runner", jsonName = "CD: Pi\\\\u00f9 bello", '
            'jsonArtist = "La \\\\\\"banda\\\\\\"" },') in generate.catalog_lua("v", [out])


def test_a_song_counts_its_different_lines_not_the_repeated_ones():
    from tools.jukebox import radiovoices as rv
    lines = ["One line", "Two line", "Three line", "Four line"] + ["[img=music] Beats [img=music]"] * 4
    cd = rv.GameCD(media=MEDIA, title="CD", author="A", year=None, lines=lines)
    keys = [rv.normalize(t) for t in lines]
    own = rv.Song("RV_s_own_0", 60, set(keys[:4]))
    other = rv.Song("RV_s_zz_0", 60, {keys[4]})                    # another CD's song: one line, four times here
    assert rv.plan(cd, {}, {"s_aaaa": own, "s_zzzz": other}).songs == [("s_aaaa", "One line")]
    two = rv.GameCD(media=MEDIA, title="Eurodance", author="A", year=None,
                    lines=["Drei zwei eins"] + ["[img=music] Beats [img=music]"] * 5)
    both = rv.Song("RV_s_e_0", 60, {rv.normalize(t) for t in two.lines})
    assert rv.plan(two, {}, {"s_e": both}).songs == [("s_e", "Drei zwei eins")]   # two different lines: both needed


# ------------------------------------------------------------------------------------------------ key, numbers, GitHub


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_a_new_key_makes_new_files_and_keeps_the_old_key(tmp_path):
    music = tmp_path / "music"
    album(music, "uno", [("a", 6)])
    first = build.build(music, tmp_path / "dist")
    old_key = package.read_key(music, False)
    second = build.build(music, tmp_path / "dist", new_key=True)
    new_key = package.read_key(music, False)
    assert new_key != old_key and second.version != first.version
    names = lambda r: {a["asset"] for a in json.loads((r.folder / "manifest.json").read_text())["albums"]}  # noqa: E731
    assert names(first).isdisjoint(names(second))                  # GitHub gets the new files: other names
    assert package.verify(second.folder, new_key) == []
    assert (music / f"jukebox.key.{package.key_id(old_key)}").read_text().strip() == old_key.hex()


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_a_folder_that_lost_its_numbers_or_its_key_stops(tmp_path):
    music = tmp_path / "music"
    album(music, "uno", [("a", 6)])
    build.build(music, tmp_path / "dist")
    before = sorted(p.name for p in (tmp_path / "dist").iterdir())
    lock_file = music / "jukebox.lock.json"
    saved = lock_file.read_text(encoding="utf-8")
    lock_file.unlink()
    with pytest.raises(SourceError, match="Manca jukebox.lock.json"):
        build.build(music, tmp_path / "dist")
    lock_file.write_text(saved, encoding="utf-8")
    (music / "jukebox.key").unlink()
    with pytest.raises(SourceError, match="Manca jukebox.key"):
        build.build(music, tmp_path / "dist")
    assert sorted(p.name for p in (tmp_path / "dist").iterdir()) == before
    assert build.build(music, tmp_path / "dist", new_key=True).version


def test_publish_refuses_a_number_given_to_another_album():
    published = {"albums": [{"key": 1, "id": "uno"}, {"key": 2, "id": "due"}]}
    publish.check_numbers(published, {"albums": [{"key": 1, "id": "uno"}, {"key": 3, "id": "tre"}]})
    publish.check_numbers(None, {"albums": [{"key": 1, "id": "altro"}]})
    with pytest.raises(SourceError, match="numero 2"):
        publish.check_numbers(published, {"albums": [{"key": 2, "id": "tre"}]})


def test_an_asset_on_github_counts_only_when_it_is_really_that_file():
    sha = "ab" * 32
    good = {"name": "x", "size": 10, "state": "uploaded", "digest": f"sha256:{sha}"}
    assert publish._uploaded(good, 10, sha)
    assert publish._uploaded({**good, "digest": None}, 10, sha)      # an older GitHub without digest: the size
    assert not publish._uploaded(None, 10, sha)
    assert not publish._uploaded({**good, "state": "starter"}, 10, sha)
    assert not publish._uploaded({**good, "size": 9}, 10, sha)
    assert not publish._uploaded({**good, "digest": "sha256:" + "cd" * 32}, 10, sha)


def test_a_package_cannot_write_outside_the_mod(tmp_path):
    folder = tmp_path / "pkg"
    folder.mkdir()
    catalog = package.make_zip({"/fuori.txt": b"x"})
    (folder / "catalog.zip").write_bytes(catalog)
    (folder / "manifest.json").write_text(json.dumps({"catalog": {"asset": "catalog.zip"}, "albums": []}))
    with pytest.raises(SourceError, match="Percorso non valido"):
        publish.stage_mod(folder, tmp_path / "mod", None)


def test_the_cache_keeps_only_what_the_last_build_used(tmp_path):
    cache = tmp_path / audio.CACHE
    for name in ("used", "old", "half.tmp"):
        (cache / name).mkdir(parents=True)
    assert audio.prune_cache(tmp_path, {"used"}) == 2
    assert [p.name for p in cache.iterdir()] == ["used"]


# ------------------------------------------------------------------------------------------------ covers


def picture(mode: str, size=(200, 100), colour=None, exif_orientation=None, fmt="PNG") -> bytes:
    from PIL import Image
    image = Image.new(mode, size, colour if colour is not None else 0)
    out = __import__("io").BytesIO()
    if exif_orientation:
        exif = Image.Exif()
        exif[0x0112] = exif_orientation
        image.save(out, format=fmt, exif=exif.tobytes())
    else:
        image.save(out, format=fmt)
    return out.getvalue()


def test_covers_are_turned_flattened_and_never_white_by_mistake():
    turned = generate.open_cover(picture("RGB", (200, 100), (10, 20, 30), exif_orientation=6, fmt="JPEG"))
    assert turned.size == (100, 200)                                  # the camera said: rotate
    clear = generate.open_cover(picture("RGBA", (10, 10), (0, 0, 0, 0)))
    assert clear.getpixel((5, 5)) == generate.COVER_BACKGROUND        # transparent on the background, not black
    grey = generate.open_cover(picture("I;16", (10, 10), 32768))
    assert grey.getpixel((5, 5))[0] in range(120, 136)                # 16-bit mid grey stays mid grey
    assert generate.open_cover(picture("CMYK", (10, 10), (0, 0, 0, 0), fmt="JPEG")).mode == "RGB"


@pytest.mark.skipif(not FFMPEG, reason="ffmpeg is not installed")
def test_a_cover_that_does_not_open_stops_before_any_audio(tmp_path):
    folder = album(tmp_path, "uno", [("a", 6)], cover="cover.png")
    (folder / "cover.png").write_bytes(b"not a picture")
    with pytest.raises(SourceError, match="copertina cover.png non si apre"):
        build.validate(tmp_path)
