#!/usr/bin/env python3
"""Run PHP's built-in syntax checker for each supplied PHP file."""

from __future__ import annotations

import subprocess
import sys


def main() -> int:
    if not sys.argv[1:]:
        return 0

    failed = False
    for path in sys.argv[1:]:
        result = subprocess.run(["php", "-l", path], check=False)
        failed = failed or result.returncode != 0
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
