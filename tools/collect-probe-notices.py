#!/usr/bin/env python3
"""Collect published notices for the optional probe from its local build cache."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
destination = Path(sys.argv[1])
cache = root / "build/cargo-home/registry/src"
lock = (root / "tools/coredevice-probe/Cargo.lock").read_text()
parts = [
    "AudioMix optional CoreDevice probe: third-party notices\n",
    "The probe uses idevice (MIT) and Rust registry dependencies.\n"
    "The following files are reproduced from cached packages in the locked build.\n"
    "Some packages are build-time dependencies or platform alternatives.\n",
    "idevice — https://github.com/jkcoxson/idevice\n"
    + (root / "research/idevice/LICENSE.txt").read_text(),
]
count = 0
for block in lock.split("[[package]]")[1:]:
    if 'source = "registry+' not in block:
        continue
    name = re.search(r'^name = "([^"]+)"', block, re.M).group(1)
    version = re.search(r'^version = "([^"]+)"', block, re.M).group(1)
    candidates = sorted(cache.glob("*/" + name + "-" + version))
    if not candidates:
        continue  # Unbuilt optional/foreign-platform packages are not in this cache.
    package = candidates[0]
    files = sorted(p for p in package.iterdir() if p.is_file()
                   and re.match(r"^(licen[sc]e|copying|notice)", p.name, re.I))
    for directory in (package / "LICENSES", package / "licenses"):
        if directory.is_dir():
            files.extend(sorted(p for p in directory.rglob("*") if p.is_file()))
    if not files:
        # A few published crates supply their license in package metadata only.
        files = [package / "Cargo.toml"]
        files.extend(sorted(package.glob("README*")))
    parts.append("\n" + "=" * 72 + "\n" + name + " " + version + "\n")
    for file in files:
        parts.append("\n--- " + str(file.relative_to(package)) + " ---\n")
        parts.append(file.read_text(errors="replace"))
    count += 1
if not count:
    raise SystemExit("Probe dependency source cache is missing; build the optional probe before packaging it.")
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n".join(parts))
print("Collected notices from", count, "cached probe dependencies")
