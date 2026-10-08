#!/usr/bin/env python3
"""Pre-upload checks against the TF3 modding guidelines. Exit code 1 if any check fails.

Run tools/build.py first so _content.json is current (tools/check.sh does that).
"""
import json
import pathlib
import re
import struct
import sys

MOD = pathlib.Path(__file__).resolve().parent.parent / "mod" / "pgrace_closest_consumer"

# Tags accepted by the game (taken from the TF3 build 40408 binary).
KNOWN_TAGS = {
    "Temperate", "Subarctic", "Tropical", "Map/Savegame", "Savegame", "Locomotive", "Wagon",
    "Multiple Unit", "Plane", "Rail Station", "Road Station", "Airport/Heliport", "Track/Road",
    "Track/Street", "Track", "Road", "Tunnel", "Rail Crossing", "Road Construction",
    "Track Construction", "Building", "Town Building", "Vegetation", "Other Asset", "Script Mod",
    "Resident", "Sound", "Shader", "Campaign", "Localization",
}
TEXT_SUFFIXES = {".lua", ".tl", ".json", ".html", ".md", ".txt"}
BALLAST_SUFFIXES = {".psd", ".xcf", ".fbx", ".blend", ".bak", ".tmp", ".orig", ".swp"}
SEVERITIES = {"None", "Warning", "Critical"}
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_MOD_BYTES = 500 * 1024 * 1024

errors: list[str] = []
warnings: list[str] = []


def image_size(path: pathlib.Path):
    data = path.read_bytes()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":  # JPEG: walk segments to the first SOFn marker
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            length = struct.unpack(">H", data[i + 2:i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            i += 2 + length
    return None


files = sorted(p for p in MOD.rglob("*"))
total = 0
for p in files:
    rel = p.relative_to(MOD).as_posix()
    if not re.fullmatch(r"[a-z0-9_.@-]+", p.name):
        errors.append(f"name not lowercase/plain: {rel}")
    if p.is_dir():
        if not any(p.iterdir()):
            errors.append(f"empty folder: {rel}")
        continue
    total += p.stat().st_size
    if p.suffix in BALLAST_SUFFIXES or p.name.endswith("~"):
        errors.append(f"source/temp file should not ship: {rel}")
    if p.suffix in TEXT_SUFFIXES:
        raw = p.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            errors.append(f"UTF-8 BOM: {rel}")
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(f"not UTF-8: {rel}")
if total > MAX_MOD_BYTES:
    errors.append(f"mod is {total / 1e6:.1f} MB, over 500 MB")

mod = json.loads((MOD / "mod.json").read_text())
if mod.get("modId") != MOD.name or not re.fullmatch(r"[a-z0-9_]+", mod.get("modId", "")):
    errors.append(f"modId {mod.get('modId')!r} must match folder {MOD.name!r} and use [a-z0-9_]")
if not isinstance(mod.get("revision"), int) or mod["revision"] < 1:
    errors.append("mod.json revision must be an integer >= 1")
for key in ("severityAdd", "severityRemove"):
    if mod.get(key) not in SEVERITIES:
        errors.append(f"mod.json {key} must be one of {sorted(SEVERITIES)}")

info = json.loads((MOD / "_metadata" / "modinfo.json").read_text())
for key, limit in (("name", 32), ("summary", 100)):
    value = info.get(key) or ""
    if not value or len(value) > limit or "\n" in value:
        errors.append(f"modinfo {key} must be 1-{limit} chars without line breaks (is {len(value)})")
if not info.get("authors"):
    errors.append("modinfo authors is empty")
unknown = [t for t in info.get("tags") or [] if t not in KNOWN_TAGS]
if not info.get("tags") or unknown:
    errors.append(f"modinfo tags must be non-empty and from the supported list (unknown: {unknown})")

meta = MOD / "_metadata"
images = sorted(p for p in meta.iterdir() if re.fullmatch(r"\d+\.(png|jpg)", p.name))
if not any(p.stem == "0" for p in images):
    warnings.append("no cover image (_metadata/0.png or 0.jpg)")
for p in images:
    size = image_size(p)
    if size != (1920, 1080):
        errors.append(f"{p.name} is {size}, must be 1920x1080")
    if p.stat().st_size > MAX_IMAGE_BYTES:
        errors.append(f"{p.name} is {p.stat().st_size / 1e6:.1f} MB, max 8 MB")

content = MOD / "content"
listed = json.loads((MOD / "_content.json").read_text())["files"]
actual = sorted(p.relative_to(content).as_posix() for p in content.rglob("*") if p.is_file())
if listed != actual:
    errors.append("_content.json is stale; run python3 tools/build.py")

for w in warnings:
    print(f"WARN  {w}")
for e in errors:
    print(f"FAIL  {e}")
print(f"{len(files)} paths, {total / 1e3:.0f} kB, {len(images)} image(s): "
      f"{'OK' if not errors else str(len(errors)) + ' problem(s)'}")
sys.exit(1 if errors else 0)
