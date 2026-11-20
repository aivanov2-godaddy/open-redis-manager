#!/usr/bin/env python3
"""Unit checks for sanitized live cPanel smoke assertions."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys

SCRIPT = Path(__file__).with_name("cpanel-live-smoke.py")
SPEC = importlib.util.spec_from_file_location("cpanel_live_smoke", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("unable to load the live cPanel smoke module")
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


def check(condition: bool, description: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {description}")


reachable_page = '''
<main>
  <section class="orm-card" aria-labelledby="orm-podman-title">
    <h3 id="orm-podman-title">Existing cPanel Podman caches</h3>
    <article><p><strong>Status:</strong> Reachable · version 6.2.24</p></article>
  </section>
</main>
'''
unavailable_page = reachable_page.replace("Reachable", "Unavailable")
unrelated_section = '''
<section aria-labelledby="other-title"><strong>Status:</strong> Reachable</section>
'''

check(SMOKE.page_has_reachable_podman_cache(reachable_page), "accept the reachable Podman section")
check(not SMOKE.page_has_reachable_podman_cache(unavailable_page), "reject an unavailable Podman socket")
check(not SMOKE.page_has_reachable_podman_cache("<p>Status: Reachable</p>"), "require the Podman section")
check(not SMOKE.page_has_reachable_podman_cache(unrelated_section), "ignore reachable status outside the Podman section")
print("Live cPanel smoke assertions passed: 4 checks.")
