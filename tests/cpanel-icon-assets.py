#!/usr/bin/env python3
"""Check cPanel Jupiter icon registration and the approved ORM brand mark."""

from __future__ import annotations

import json
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "packaging" / "cpanel"
SVG_NS = "{http://www.w3.org/2000/svg}"


def has_flat_pixel_paths(root: ET.Element, expected_count: int, size: int) -> bool:
    paths = list(root.iter(f"{SVG_NS}path"))
    if len(paths) != expected_count or not all(path in root for path in paths):
        return False
    if any(node.get("transform") for node in root.iter()):
        return False
    return all(
        all(abs(float(value)) <= size for value in re.findall(r"[-+]?(?:\d*\.)?\d+", path.get("d", "")))
        for path in paths
    )


def main() -> int:
    entries = json.loads((ROOT / "install.json").read_text(encoding="utf-8"))
    group = next((entry for entry in entries if entry.get("type") == "group"), None)
    feature = next((entry for entry in entries if entry.get("type") == "link"), None)
    if group is None or group.get("icon") != "orm-cpanel-group-v2.svg":
        raise SystemExit("the cPanel group must use the cache-busted ORM group SVG")
    if feature is None or feature.get("icon") != "orm-cpanel-feature-v2.svg":
        raise SystemExit("the cPanel launcher must use the cache-busted ORM feature SVG")

    svg_path = ROOT / "icons" / "orm-cpanel-group-v2.svg"
    root = ET.parse(svg_path).getroot()
    paths = list(root.iter(f"{SVG_NS}path"))
    fills = {node.get("fill") for node in paths}
    if (
        root.tag != f"{SVG_NS}svg"
        or (root.get("width"), root.get("height")) != ("32", "32")
        or root.get("viewBox") != "0 0 32 32"
        or not any(node.get("fill") == "#D92D20" for node in root.iter(f"{SVG_NS}rect"))
        or not {"#FFFFFF", "#FFE5E1", "#F9BDB6"}.issubset(fills)
        or not has_flat_pixel_paths(root, expected_count=6, size=32)
    ):
        raise SystemExit("the 32x32 cPanel group SVG must use the approved cache-cube mark as explicit pixel-space paths without transforms")

    feature_svg = ET.parse(ROOT / "icons" / "orm-cpanel-feature-v2.svg").getroot()
    if (
        feature_svg.tag != f"{SVG_NS}svg"
        or (feature_svg.get("width"), feature_svg.get("height")) != ("48", "48")
        or feature_svg.get("viewBox") != "0 0 48 48"
        or not has_flat_pixel_paths(feature_svg, expected_count=6, size=48)
    ):
        raise SystemExit("the cPanel launcher SVG must use the approved cache-cube mark as explicit pixel-space paths without transforms")

    pngs = []
    for name in ("orm-cpanel-group-v2", "orm-cpanel-feature-v2"):
        png = (ROOT / "icons" / f"{name}.png").read_bytes()
        if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
            raise SystemExit(f"{name}.png is not a valid PNG")
        if struct.unpack(">II", png[16:24]) != (48, 48):
            raise SystemExit(f"{name}.png must be 48x48 pixels")
        if png[25] != 6:
            raise SystemExit(f"{name}.png must use RGBA so the canvas remains transparent")
        pngs.append(png)
    if pngs[0] != pngs[1]:
        raise SystemExit("the cPanel group PNG fallback and launcher PNG must use identical approved artwork")

    print("cPanel icon assets passed: approved red tile and white cache cube at 32px SVG and matching 48px RGBA PNGs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
