#!/usr/bin/env python3
"""Check cPanel Jupiter icon registration and the transparent ORM glyphs."""

from __future__ import annotations

import json
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "packaging" / "cpanel"
SVG_NS = "{http://www.w3.org/2000/svg}"


def main() -> int:
    entries = json.loads((ROOT / "install.json").read_text(encoding="utf-8"))
    group = next((entry for entry in entries if entry.get("type") == "group"), None)
    feature = next((entry for entry in entries if entry.get("type") == "link"), None)
    if group is None or group.get("icon") != "orm-cpanel-group-v2.svg":
        raise SystemExit("the cPanel group must use the cache-busted ORM group SVG")
    if feature is None or feature.get("icon") != "orm-cpanel-feature-v2.png":
        raise SystemExit("the cPanel launcher must use the cache-busted ORM feature PNG")

    for name, size in (("orm-cpanel-group-v2", 32),):
        svg_path = ROOT / "icons" / f"{name}.svg"
        root = ET.parse(svg_path).getroot()
        group_node = root.find(f"{SVG_NS}g")
        if (
            root.tag != f"{SVG_NS}svg"
            or (root.get("width"), root.get("height")) != (str(size), str(size))
            or root.get("viewBox") != f"0 0 {size} {size}"
            or group_node is None
            or group_node.get("fill") != "none"
            or group_node.get("stroke") != "#D92D20"
            or len(group_node.findall(f"{SVG_NS}path")) != 2
        ):
            raise SystemExit(f"{name}.svg must be a {size}x{size} transparent red cache-tier glyph")

    for name in ("orm-cpanel-group-v2", "orm-cpanel-feature-v2"):
        png = (ROOT / "icons" / f"{name}.png").read_bytes()
        if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
            raise SystemExit(f"{name}.png is not a valid PNG")
        if struct.unpack(">II", png[16:24]) != (48, 48):
            raise SystemExit(f"{name}.png must be 48x48 pixels")
        if png[25] != 6:
            raise SystemExit(f"{name}.png must use RGBA so the canvas remains transparent")

    print("cPanel icon assets passed: cache-busted 32x32 group SVG and matching RGBA PNG glyphs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
