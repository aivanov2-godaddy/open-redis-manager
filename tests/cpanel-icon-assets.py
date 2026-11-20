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
    icons = {entry["icon"] for entry in entries}
    expected = {"orm-group.svg", "orm-feature.svg"}
    if icons != expected:
        raise SystemExit(f"unexpected cPanel icon registrations: {sorted(icons)}")

    for svg_name in sorted(expected):
        stem = Path(svg_name).stem
        svg_path = ROOT / "icons" / svg_name
        png_path = ROOT / "icons" / f"{stem}.png"
        svg_root = ET.parse(svg_path).getroot()
        if (
            svg_root.tag != f"{SVG_NS}svg"
            or svg_root.get("width") != "48"
            or svg_root.get("height") != "48"
            or svg_root.get("viewBox") != "0 0 48 48"
        ):
            raise SystemExit(f"{svg_name} must be an SVG with a 48x48 viewBox")

        png = png_path.read_bytes()
        if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
            raise SystemExit(f"{png_path.name} is not a valid PNG")
        if struct.unpack(">II", png[16:24]) != (48, 48):
            raise SystemExit(f"{png_path.name} must be 48x48 pixels")

    print("cPanel icon assets passed: paired 48x48 SVG/PNG icons are registered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
