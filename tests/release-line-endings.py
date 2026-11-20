#!/usr/bin/env python3
"""Guard release inputs against Windows CRLF conversion."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    root = parser.parse_args().root.resolve()

    attributes = root / ".gitattributes"
    if "* text=auto eol=lf" not in attributes.read_text(encoding="utf-8").splitlines():
        raise SystemExit(".gitattributes must force LF for detected text files")

    required_files = root / "packaging" / "release-required-files.txt"
    paths = [line.strip() for line in required_files.read_text(encoding="utf-8").splitlines() if line.strip()]
    bad = [
        path
        for path in paths
        if Path(path).suffix.lower() not in BINARY_SUFFIXES
        and b"\r\n" in (root / path).read_bytes()
    ]
    if bad:
        raise SystemExit("CRLF found in release text inputs: " + ", ".join(bad))

    print(f"Release line endings passed for {len(paths)} required files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
