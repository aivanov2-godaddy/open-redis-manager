#!/usr/bin/env python3
"""Check cPanel Jupiter icon names and the approved ORM artwork."""

from __future__ import annotations

import json
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "packaging" / "cpanel"
BRAND = Path(__file__).resolve().parents[1] / "assets" / "orm-mark.svg"
SVG_NS = "{http://www.w3.org/2000/svg}"


def main() -> int:
    entries = json.loads((ROOT / "install.json").read_text(encoding="utf-8"))
    group = next((entry for entry in entries if entry.get("type") == "group"), None)
    feature = next((entry for entry in entries if entry.get("type") == "link"), None)
    if group is None or group.get("icon") != "orm-group.png":
        raise SystemExit("the cPanel group must use the approved orm-group.png artwork")
    if feature is None or feature.get("icon") != "orm-feature.png":
        raise SystemExit("the cPanel launcher must use the approved orm-feature.png artwork")

    approved = BRAND.read_text(encoding="utf-8")
    expected_feature = approved.replace('width="256" height="256"', 'width="48" height="48"', 1)
    expected_group = approved.replace('width="256" height="256"', 'width="32" height="32"', 1)
    expected_group = expected_group.replace(
        '<rect x="4" y="4" width="248" height="248" rx="58" fill="#D92D20"/>',
        '<path d="M62 4h132a58 58 0 0 1 58 58v132a58 58 0 0 1-58 58H62a58 58 0 0 1-58-58V62A58 58 0 0 1 62 4Z" fill="#D92D20"/>',
        1,
    )
    expected_group = expected_group.replace(
        '<rect x="5" y="5" width="246" height="246" rx="57" fill="none" stroke="#FFFFFF" stroke-opacity=".18" stroke-width="2"/>',
        '<path d="M62 5h132a57 57 0 0 1 57 57v132a57 57 0 0 1-57 57H62a57 57 0 0 1-57-57V62A57 57 0 0 1 62 5Z" fill="none" stroke="#FFFFFF" stroke-opacity=".18" stroke-width="2"/>',
        1,
    )

    for name, expected_svg, size in (
        ("orm-group.svg", expected_group, "32"),
        ("orm-feature.svg", expected_feature, "48"),
    ):
        path = ROOT / "icons" / name
        icon = ET.parse(path).getroot()
        if (
            icon.tag != f"{SVG_NS}svg"
            or (icon.get("width"), icon.get("height")) != (size, size)
            or icon.get("viewBox") != "0 0 256 256"
            or path.read_text(encoding="utf-8") != expected_svg
        ):
            raise SystemExit(f"{name} must render the approved ORM brand mark at {size}x{size}")

    for name in ("orm-feature.png", "orm-group.png"):
        png = (ROOT / "icons" / name).read_bytes()
        if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
            raise SystemExit(f"{name} is not a valid PNG")
        if struct.unpack(">II", png[16:24]) != (48, 48):
            raise SystemExit(f"{name} must be 48x48 pixels")
        if png[25] != 6:
            raise SystemExit(f"{name} must use RGBA so its rounded tile corners remain transparent")

    print("cPanel icon assets passed: approved brand SVGs and matching 48x48 RGBA PNG fallbacks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
