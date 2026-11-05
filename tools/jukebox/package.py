"""The package of a catalogue (docs/jukebox/TECHNICAL_DESIGN.md, «Il pacchetto del catalogo»):

    dist/<catalogVersion>/
      manifest.json            public: versions, the key's id, every file with its size and SHA-256
      catalog-<hash>.zip       public: items, sounds, CatalogData.lua, names, icons and covers
      a<album>-<hash>.jbm      one per album: the zip of its pieces, encrypted with AES-256-GCM

A .jbm is b"JBM1" + 12-byte nonce + ciphertext + 16-byte tag, associated data b"JukeboxMoon". The nonce is the HMAC of
the key over the zip's SHA-256: the same album always gives the same file, two different ones never the same nonce.
Zips have fixed dates and sorted entries, stored (the OGG pieces are already compressed): the same input gives the
same bytes. The package is written in a temporary folder and renamed at the end.
"""

from __future__ import annotations

import hashlib
import hmac
import io
import json
import os
import shutil
import zipfile
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"JBM1"
AAD = b"JukeboxMoon"
ZIP_DATE = (2020, 1, 1, 0, 0, 0)
KEY_FILE = "jukebox.key"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ------------------------------------------------------------------------------------------------ the key


def new_key() -> bytes:
    return os.urandom(32)


def key_id(key: bytes) -> str:
    return sha256(key)[:16]


def read_key(music: Path, create: bool) -> bytes:
    """The key of the music, in the admin's folder (jukebox.key: 64 hex characters). Made the first time."""
    path = Path(music) / KEY_FILE
    if path.exists():
        text = path.read_text(encoding="ascii").strip().lower()
        if len(text) != 64 or any(c not in "0123456789abcdef" for c in text):
            raise ValueError(f"{KEY_FILE}: non è una chiave (64 caratteri esadecimali).")
        return bytes.fromhex(text)
    if not create:
        raise ValueError(f"Manca {KEY_FILE} nella cartella della musica.")
    key = new_key()
    write_key(music, key)
    return key


def write_key(music: Path, key: bytes) -> None:
    path = Path(music) / KEY_FILE
    tmp = path.with_suffix(".tmp")
    tmp.write_text(key.hex() + "\n", encoding="ascii")
    tmp.replace(path)


def encrypt(key: bytes, plain: bytes) -> bytes:
    nonce = hmac.new(key, MAGIC + bytes.fromhex(sha256(plain)), hashlib.sha256).digest()[:12]
    return MAGIC + nonce + AESGCM(key).encrypt(nonce, plain, AAD)


def decrypt(key: bytes, blob: bytes) -> bytes:
    if blob[:4] != MAGIC or len(blob) < 4 + 12 + 16:
        raise ValueError("non è un file .jbm")
    return AESGCM(key).decrypt(blob[4:16], blob[16:], AAD)


# ------------------------------------------------------------------------------------------------ zips


def make_zip(files: dict[str, bytes]) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_STORED) as z:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=ZIP_DATE)
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            info.create_system = 0
            z.writestr(info, files[name])
    return out.getvalue()


def read_zip(data: bytes) -> dict[str, bytes]:
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        return {name: z.read(name) for name in z.namelist()}


def file_list(files: dict[str, bytes]) -> list[dict]:
    return [{"path": p, "size": len(files[p]), "sha256": sha256(files[p])} for p in sorted(files)]


# ------------------------------------------------------------------------------------------------ the package


def version_of(public: dict[str, bytes], audio: dict[str, bytes], metadata: dict) -> str:
    """16 hex characters from every file but CatalogData.lua (which contains the version) and the metadata."""
    h = hashlib.sha256()
    for path in sorted(set(public) | set(audio)):
        if path.endswith("/CatalogData.lua"):
            continue
        data = public.get(path, audio.get(path))
        h.update(f"{path}\0{sha256(data)}\n".encode())
    h.update(json.dumps(metadata, sort_keys=True, ensure_ascii=False).encode())
    return h.hexdigest()[:16]


def write_package(dist: Path, version: str, package_version: str, key: bytes, public: dict[str, bytes],
                  albums: list[tuple[int, str, dict[str, bytes]]]) -> Path:
    """albums: (key, id, {path: bytes}) of every album. Returns the package's folder."""
    dist = Path(dist)
    final = dist / version
    tmp = dist / f".{version}.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    catalog_zip = make_zip(public)
    catalog_name = f"catalog-{sha256(catalog_zip)[:16]}.zip"
    (tmp / catalog_name).write_bytes(catalog_zip)
    manifest = {
        "format": 1,
        "mod": "JukeboxMoon",
        "catalogVersion": version,
        "packageVersion": package_version,
        "keyId": key_id(key),
        "catalog": {"asset": catalog_name, "size": len(catalog_zip), "sha256": sha256(catalog_zip),
                    "files": file_list(public)},
        "albums": [],
    }
    for album_key, album_id, files in albums:
        plain = make_zip(files)
        blob = encrypt(key, plain)
        name = f"a{album_key}-{sha256(plain)[:16]}.jbm"
        (tmp / name).write_bytes(blob)
        manifest["albums"].append({"key": album_key, "id": album_id, "asset": name, "size": len(blob),
                                   "sha256": sha256(blob), "files": file_list(files)})
    (tmp / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if final.exists():
        old = dist / f".{version}.old"
        shutil.rmtree(old, ignore_errors=True)
        final.replace(old)
        tmp.replace(final)
        shutil.rmtree(old, ignore_errors=True)
    else:
        tmp.replace(final)
    return final


def verify(package: Path, key: bytes | None = None) -> list[str]:
    """Problems of a package (empty when it is good): every asset and every file against the manifest."""
    package = Path(package)
    problems = []
    manifest = json.loads((package / "manifest.json").read_text(encoding="utf-8"))
    assets = [manifest["catalog"]] + manifest["albums"]
    for asset in assets:
        path = package / asset["asset"]
        if not path.exists():
            problems.append(f"manca {asset['asset']}")
            continue
        data = path.read_bytes()
        if len(data) != asset["size"] or sha256(data) != asset["sha256"]:
            problems.append(f"{asset['asset']}: byte o impronta diversi dal manifest")
            continue
        if asset is manifest["catalog"]:
            inside = read_zip(data)
        elif key is not None:
            try:
                inside = read_zip(decrypt(key, data))
            except Exception:
                problems.append(f"{asset['asset']}: la chiave non lo apre")
                continue
        else:
            continue
        if file_list(inside) != asset["files"]:
            problems.append(f"{asset['asset']}: i file dentro non sono quelli del manifest")
    if key is not None and manifest["keyId"] != key_id(key):
        problems.append("la chiave non è quella del pacchetto")
    return problems
