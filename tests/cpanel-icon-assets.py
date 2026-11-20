#!/usr/bin/env python3
"""Check cPanel Jupiter icon names, dimensions, and PNG fallback assets."""

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
        raise SystemExit("the cPanel group must use orm-group.svg")
    if feature is None or feature.get("icon") != "orm-feature.svg":
        raise SystemExit("the cPanel launcher must use the vector icon so Jupiter can tint its transparent mark")

    for name in ("orm-group.svg", "orm-feature.svg"):
        icon = ET.parse(ROOT / "icons" / name).getroot()
        if (
            icon.tag != f"{SVG_NS}svg"
            or (icon.get("width"), icon.get("height")) != ("48", "48")
            or icon.get("viewBox") != "0 0 48 48"
            or icon.find(f"{SVG_NS}rect") is not None
        ):
            raise SystemExit(f"{name} must use its documented size and a transparent background")
        group = icon.find(f"{SVG_NS}g")
        if group is None or group.get("fill") != "none" or group.get("stroke") != "#D92D20":
            raise SystemExit(f"{name} must retain the red cube mark without an opaque tile")

    for name in ("orm-feature.png", "orm-group.png"):
        png = (ROOT / "icons" / name).read_bytes()
        if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
            raise SystemExit(f"{name} is not a valid PNG")
        if struct.unpack(">II", png[16:24]) != (48, 48):
            raise SystemExit(f"{name} must be 48x48 pixels")
        if png[25] != 6:
            raise SystemExit(f"{name} must use RGBA so its background remains transparent")

    print("cPanel icon assets passed: transparent 48x48 SVG icons and RGBA PNG fallbacks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
