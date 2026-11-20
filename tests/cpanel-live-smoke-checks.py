#!/usr/bin/env python3
"""Unit checks for sanitized live cPanel smoke assertions."""

from __future__ import annotations

import importlib.util
import io
from pathlib import Path
from contextlib import redirect_stdout
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

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
check(
    SMOKE.page_has_verified_account("<p>Verified cPanel account: <code>tester</code></p>", "tester"),
    "accept the exact authenticated account",
)
check(
    not SMOKE.page_has_verified_account("<p>Verified cPanel account: <code>other</code></p>", "tester"),
    "reject a different authenticated account",
)
check(
    not SMOKE.page_has_verified_account("<p>Other text: <code>tester</code></p>", "tester"),
    "require the verified account label",
)
check(
    SMOKE.page_has_verified_account("<p>Verified cPanel account: <code>test&#101;r</code></p>", "tester"),
    "decode escaped account text before comparison",
)

landing_url = "https://example.invalid/cpsess123/frontend/jupiter/index.html"
page_url = "https://example.invalid/cpsess123/frontend/jupiter/orm/index.live.php"
verified_page = "<p>Verified cPanel account: <code>tester</code></p>"
with (
    patch.object(SMOKE.os, "geteuid", return_value=0, create=True),
    patch.object(SMOKE, "select_account", return_value="tester"),
    patch.object(SMOKE, "create_session_url", return_value="https://example.invalid/cpsess123/login"),
    patch.object(
        SMOKE,
        "read_page",
        side_effect=[
            (200, "", landing_url),
            (200, verified_page, page_url),
            (200, verified_page, page_url),
        ],
    ) as read_page,
    redirect_stdout(io.StringIO()),
):
    smoke_result = SMOKE.run(None)

check(smoke_result == 0, "pass when normal and query-spoof requests retain the SSO account")
check(read_page.call_count == 3, "make both the landing, normal, and spoofed requests")
query = parse_qs(urlsplit(read_page.call_args_list[2].args[1]).query)
check(
    query == {"user": ["root"], "username": ["root"], "account": ["root"]},
    "send the expected account query-spoof probe",
)
print("Live cPanel smoke assertions passed: 11 checks.")
