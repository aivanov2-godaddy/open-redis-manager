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
    if group is None or group.get("icon") != "orm-group.svg":
        raise SystemExit("the cPanel group must use the orm-group.svg icon")
    if feature is None or feature.get("icon") != "orm-feature.svg":
        raise SystemExit("the cPanel launcher must use the orm-feature.svg icon")

    for name in ("orm-group", "orm-feature"):
        svg_path = ROOT / "icons" / f"{name}.svg"
        root = ET.parse(svg_path).getroot()
        group_node = root.find(f"{SVG_NS}g")
        if (
            root.tag != f"{SVG_NS}svg"
            or (root.get("width"), root.get("height")) != ("48", "48")
            or root.get("viewBox") != "0 0 48 48"
            or group_node is None
            or group_node.get("fill") != "none"
            or group_node.get("stroke") != "#D92D20"
            or len(group_node.findall(f"{SVG_NS}path")) != 2
        ):
            raise SystemExit(f"{name}.svg must be a 48x48 transparent red cache-tier glyph")

        png = (ROOT / "icons" / f"{name}.png").read_bytes()
        if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
            raise SystemExit(f"{name}.png is not a valid PNG")
        if struct.unpack(">II", png[16:24]) != (48, 48):
            raise SystemExit(f"{name}.png must be 48x48 pixels")
        if png[25] != 6:
            raise SystemExit(f"{name}.png must use RGBA so the canvas remains transparent")

    print("cPanel icon assets passed: transparent 48x48 SVG glyphs and RGBA PNG fallbacks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
