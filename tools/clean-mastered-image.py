#!/usr/bin/env python3
"""Remove DiscRecording's default FinderInfo from an app in a raw HFS+ image.

makehybrid writes a Finder location of (-1, -1) even for plain Mach-O files.
That metadata becomes com.apple.FinderInfo on mount and fails strict codesign
verification. Clear only the app tree's 32-byte catalog FinderInfo fields.
File data, signatures, permissions, resource forks and other attributes are kept.
Run on the generated raw image before UDZO compression and image signing.
"""
from pathlib import Path
import struct
import sys

image_path = Path(sys.argv[1])
app_name = sys.argv[2]
image = image_path.read_bytes()

def u16(data, offset):
    return struct.unpack_from(">H", data, offset)[0]

def u32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(image[:2] == b"ER", "Expected makehybrid's Apple partition map")
sector_bytes = u16(image, 2)
require(sector_bytes in (512, 2048), "Unsupported partition sector size")
volume_origin = None
for index in range(1, 64):
    entry = image[index * sector_bytes:(index + 1) * sector_bytes]
    if entry[:2] != b"PM":
        break
    if entry[48:80].split(b"\0")[0] == b"Apple_HFS":
        volume_origin = u32(entry, 8) * sector_bytes
        break
require(volume_origin is not None, "No HFS+ partition found")
header = image[volume_origin + 1024:volume_origin + 1536]
require(header[:2] == b"H+", "Expected an HFS+ volume")
block_bytes = u32(header, 40)
require(block_bytes >= 512 and block_bytes & (block_bytes - 1) == 0, "Invalid HFS+ block size")
# HFSPlusVolumeHeader.catalogFile is an 80-byte HFSPlusForkData at offset 272.
catalog_bytes = struct.unpack_from(">Q", header, 272)[0]
require(0 < catalog_bytes <= 16 * 1024 * 1024, "Unexpected catalog size")
extents = [struct.unpack_from(">II", header, 288 + index * 8) for index in range(8)]
catalog = bytearray()
physical_ranges = []
for start, count in extents:
    if not count:
        continue
    begin = volume_origin + start * block_bytes
    length = min(count * block_bytes, catalog_bytes - len(catalog))
    require(begin + length <= len(image), "Catalog extent outside the image")
    if length:
        physical_ranges.append((begin, length))
        catalog.extend(image[begin:begin + length])
require(len(catalog) == catalog_bytes, "Catalog overflow extents are unsupported")
node_bytes = u16(catalog, 32)
require(512 <= node_bytes <= 32768 and catalog_bytes % node_bytes == 0, "Invalid catalog nodes")
next_leaf = u32(catalog, 24)
records = []
visited = set()
while next_leaf:
    require(next_leaf not in visited and next_leaf * node_bytes < len(catalog), "Invalid catalog leaf chain")
    visited.add(next_leaf)
    base = next_leaf * node_bytes
    node = catalog[base:base + node_bytes]
    require(node[8] == 255, "Expected a catalog leaf node")
    count = u16(node, 10)
    require((count + 1) * 2 + 14 < node_bytes, "Invalid catalog record count")
    for index in range(count):
        begin = u16(node, node_bytes - (index + 1) * 2)
        end = u16(node, node_bytes - (index + 2) * 2)
        require(14 <= begin < end <= node_bytes - (count + 1) * 2, "Invalid record bounds")
        key_bytes = u16(node, begin)
        data = begin + 2 + key_bytes
        require(key_bytes >= 6 and data + 2 <= end, "Invalid catalog key")
        name_units = u16(node, begin + 6)
        require(begin + 8 + name_units * 2 <= data, "Invalid catalog name")
        name = node[begin + 8:begin + 8 + name_units * 2].decode("utf-16be")
        kind = u16(node, data)
        if kind in (1, 2):  # folder or file; thread records have no FinderInfo.
            require(data + 80 <= end, "Short catalog file/folder record")
            records.append((u32(node, data + 8), u32(node, begin + 2), name, base + data + 48))
    next_leaf = u32(node, 0)

roots = [record[0] for record in records if record[1] == 2 and record[2] == app_name]
require(len(roots) == 1, "Expected exactly one app at the volume root")
owned = set(roots)
while True:
    expanded = owned | {cnid for cnid, parent, _, _ in records if parent in owned}
    if expanded == owned:
        break
    owned = expanded
changed = 0
for cnid, _, _, offset in records:
    if cnid in owned and any(catalog[offset:offset + 32]):
        catalog[offset:offset + 32] = bytes(32)
        changed += 1
require(changed > 0, "No default app FinderInfo was found to clean")
# All parsing/validation completes before any bytes are written.
with image_path.open("r+b") as output:
    logical = 0
    for physical, length in physical_ranges:
        output.seek(physical)
        output.write(catalog[logical:logical + length])
        logical += length
print("Removed mastered FinderInfo from", changed, "app catalog entries")
