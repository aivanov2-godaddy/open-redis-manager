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
    if feature is None or feature.get("icon") != "orm-feature.png":
        raise SystemExit("the cPanel launcher must explicitly use the PNG artwork")

    group_svg = ET.parse(ROOT / "icons" / "orm-group.svg").getroot()
    if (
        group_svg.tag != f"{SVG_NS}svg"
        or group_svg.get("width") != "32"
        or group_svg.get("height") != "32"
        or group_svg.get("viewBox") != "0 0 48 48"
    ):
        raise SystemExit("orm-group.svg must expose the 48-unit mark at cPanel's 32x32 group size")

    for name in ("orm-feature.png", "orm-group.png"):
        png = (ROOT / "icons" / name).read_bytes()
        if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
            raise SystemExit(f"{name} is not a valid PNG")
        if struct.unpack(">II", png[16:24]) != (48, 48):
            raise SystemExit(f"{name} must be 48x48 pixels")

    print("cPanel icon assets passed: 32x32 SVG group and explicit 48x48 PNG launcher.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
