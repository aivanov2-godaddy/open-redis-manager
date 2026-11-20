#!/usr/bin/env python3
"""Check the cPanel Jupiter registration and v4 ORM mark assets."""

from __future__ import annotations

import json
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "packaging" / "cpanel"
ICON_NAMES = ("orm-cpanel-group-v4", "orm-cpanel-feature-v4")
SVG_NS = "{http://www.w3.org/2000/svg}"


def check_svg(path: Path, size: int) -> None:
    root = ET.parse(path).getroot()
    rectangles = list(root.iter(f"{SVG_NS}rect"))
    paths = list(root.iter(f"{SVG_NS}path"))
    if (
        root.tag != f"{SVG_NS}svg"
        or (root.get("width"), root.get("height"), root.get("viewBox")) != (str(size), str(size), f"0 0 {size} {size}")
        or len(rectangles) != 2
        or len(paths) != 6
        or any(node.get("transform") for node in root.iter())
        or rectangles[0].get("fill") != "#D92D20"
        or any(path_node.get("fill") not in {"#FFFFFF", "#FFE5E1", "#F9BDB6", "#D92D20", "none"} for path_node in paths)
    ):
        raise SystemExit(f"{path.name} must show the approved mark with direct {size}x{size} SVG paths")


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
        raise SystemExit(f"{path.name} must contain the Redis-red ORM mark")
    white_detail = sum(
        rows[y][x * 4] > 220
        and rows[y][x * 4 + 1] > 220
        and rows[y][x * 4 + 2] > 220
        and alpha(x, y) > 200
        for y in range(height)
        for x in range(width)
    )
    if white_detail < 50:
        raise SystemExit(f"{path.name} must retain the white cache-cube detail on the red brand tile")
    return data


def main() -> int:
    entries = json.loads((ROOT / "install.json").read_text(encoding="utf-8"))
    group = next((entry for entry in entries if entry.get("type") == "group"), None)
    feature = next((entry for entry in entries if entry.get("type") == "link"), None)
    if group is None or group.get("icon") != f"{ICON_NAMES[0]}.svg":
        raise SystemExit("the cPanel group must use the v4 direct-path SVG")
    if feature is None or feature.get("icon") != f"{ICON_NAMES[1]}.svg":
        raise SystemExit("the cPanel launcher must use the v4 direct-path SVG")

    check_svg(ROOT / "icons" / f"{ICON_NAMES[0]}.svg", 32)
    check_svg(ROOT / "icons" / f"{ICON_NAMES[1]}.svg", 48)
    pngs = [check_png(ROOT / "icons" / f"{name}.png") for name in ICON_NAMES]
    if pngs[0] != pngs[1]:
        raise SystemExit("the cPanel group PNG fallback and launcher PNG must use identical artwork")

    print("cPanel icon assets passed: v4 SVG sprite art and 48x48 PNG fallbacks preserve the approved mark.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
