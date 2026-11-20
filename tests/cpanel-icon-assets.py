#!/usr/bin/env python3
"""Check the cPanel Jupiter icon registration and transparent red artwork."""

from __future__ import annotations

import json
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "packaging" / "cpanel"
SVG_NS = "{http://www.w3.org/2000/svg}"
ICON_NAMES = ("orm-cpanel-group-v3", "orm-cpanel-feature-v3")
RED = "#D92D20"


def check_svg(path: Path, size: int) -> None:
    root = ET.parse(path).getroot()
    paths = list(root.iter(f"{SVG_NS}path"))
    if (
        root.tag != f"{SVG_NS}svg"
        or (root.get("width"), root.get("height")) != (str(size), str(size))
        or root.get("viewBox") != f"0 0 {size} {size}"
        or len(paths) != 5
        or len(list(root)) != 7  # title, description, and five direct paths
        or any(node.tag not in {f"{SVG_NS}title", f"{SVG_NS}desc", f"{SVG_NS}path"} for node in root)
        or any(node.get("transform") for node in root.iter())
        or any(path_node.get("fill") != "none" for path_node in paths)
        or any(path_node.get("stroke") != RED for path_node in paths)
        or any(float(path_node.get("stroke-width", "0")) <= 0 for path_node in paths)
        or not all(
            abs(float(value)) <= size
            for path_node in paths
            for value in re.findall(r"[-+]?(?:\d*\.)?\d+", path_node.get("d", ""))
        )
    ):
        raise SystemExit(f"{path.name} must be transparent red line art in a {size}x{size} pixel-space viewBox")


def check_png(path: Path) -> bytes:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise SystemExit(f"{path.name} is not a valid PNG")
    if struct.unpack(">II", data[16:24]) != (48, 48) or data[25] != 6:
        raise SystemExit(f"{path.name} must be a 48x48 RGBA PNG")
    width, height = struct.unpack(">II", data[16:24])
    compressed = bytearray()
    offset = 8
    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8]
        chunk = data[offset + 8 : offset + 8 + length]
        if kind == b"IDAT":
            compressed.extend(chunk)
        offset += 12 + length
        if kind == b"IEND":
            break
    raw = zlib.decompress(compressed)
    stride = width * 4
    rows: list[bytearray] = []
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        scanline = bytearray(raw[cursor + 1 : cursor + 1 + stride])
        cursor += stride + 1
        previous = rows[-1] if rows else bytearray(stride)
        for index in range(stride):
            left = scanline[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 1:
                scanline[index] = (scanline[index] + left) & 0xFF
            elif filter_type == 2:
                scanline[index] = (scanline[index] + above) & 0xFF
            elif filter_type == 3:
                scanline[index] = (scanline[index] + ((left + above) // 2)) & 0xFF
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
                predictor = left if distances[0] <= distances[1] and distances[0] <= distances[2] else (
                    above if distances[1] <= distances[2] else upper_left
                )
                scanline[index] = (scanline[index] + predictor) & 0xFF
            elif filter_type != 0:
                raise SystemExit(f"{path.name} uses unsupported PNG filter {filter_type}")
        rows.append(scanline)
    alpha = lambda x, y: rows[y][x * 4 + 3]
    if any(alpha(x, y) != 0 for x, y in ((0, 0), (47, 0), (0, 47), (47, 47))):
        raise SystemExit(f"{path.name} must have a transparent canvas, without a solid background tile")
    if not any(
        rows[y][x * 4] > 150
        and rows[y][x * 4 + 1] < 100
        and rows[y][x * 4 + 2] < 100
        and alpha(x, y) > 0
        for y in range(height)
        for x in range(width)
    ):
        raise SystemExit(f"{path.name} must contain visible Redis-red icon pixels")
    return data


def main() -> int:
    entries = json.loads((ROOT / "install.json").read_text(encoding="utf-8"))
    group = next((entry for entry in entries if entry.get("type") == "group"), None)
    feature = next((entry for entry in entries if entry.get("type") == "link"), None)
    if group is None or group.get("icon") != f"{ICON_NAMES[0]}.svg":
        raise SystemExit("the cPanel group must use the cache-busted v3 group SVG")
    if feature is None or feature.get("icon") != f"{ICON_NAMES[1]}.svg":
        raise SystemExit("the cPanel launcher must use the cache-busted v3 feature SVG")

    check_svg(ROOT / "icons" / f"{ICON_NAMES[0]}.svg", 32)
    check_svg(ROOT / "icons" / f"{ICON_NAMES[1]}.svg", 48)
    pngs = [check_png(ROOT / "icons" / f"{name}.png") for name in ICON_NAMES]
    if pngs[0] != pngs[1]:
        raise SystemExit("the cPanel group PNG fallback and launcher PNG must use identical artwork")

    print("cPanel icon assets passed: transparent red line-art SVGs and matching 48x48 RGBA PNGs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
