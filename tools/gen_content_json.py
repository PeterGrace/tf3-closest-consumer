#!/usr/bin/env python3
"""Writes the mod's _content.json, the file index that TF3 mods ship with."""
import json
import pathlib

mod = pathlib.Path(__file__).resolve().parent.parent / "mod" / "pgrace_closest_consumer"
content = mod / "content"
files = sorted(p.relative_to(content).as_posix() for p in content.rglob("*") if p.is_file())
(mod / "_content.json").write_text(json.dumps({"archives": None, "files": files}, indent=4) + "\n")
print(f"_content.json: {len(files)} files")
