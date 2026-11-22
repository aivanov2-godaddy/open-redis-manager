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
first_run_page = '''
<h3 id="orm-setup-title">First-time setup</h3>
<a href="?orm_setup=native">Native service</a>
<a href="?orm_setup=podman">cPanel EA Podman</a>
'''
setup_page_url = "https://example.invalid/cpsess123/frontend/jupiter/orm/index.live.php"
check(SMOKE.page_has_first_run_setup(first_run_page), "accept both first-run backend choices")
check(
    not SMOKE.page_has_first_run_setup(first_run_page.replace('href="?orm_setup=podman"', "")),
    "require the Podman setup choice alongside native",
)
check(
    SMOKE.page_has_setup_route("<h4>Native service readiness</h4><a>Back to setup choices</a>", "native"),
    "recognize the native setup route",
)
check(
    SMOKE.page_has_setup_route("<h4>cPanel EA Podman readiness</h4><a>Back to setup choices</a>", "podman"),
    "recognize the Podman setup route",
)
check(
    not SMOKE.page_has_setup_route("<h4>Native service readiness</h4>", "podman"),
    "do not confuse setup-route result types",
)
for mode in ("native", "podman"):
    check(
        parse_qs(urlsplit(SMOKE.setup_route_url(setup_page_url, mode)).query) == {"orm_setup": [mode]},
        f"build only the fixed {mode} query route",
    )
    check(
        SMOKE.url_has_setup_mode(SMOKE.setup_route_url(setup_page_url, mode), mode),
        f"recognize a preserved {mode} selector",
    )
check(
    not SMOKE.url_has_setup_mode(setup_page_url, "native"),
    "reject a redirect that drops the setup selector",
)
try:
    SMOKE.setup_route_url(setup_page_url, "start")
except ValueError as error:
    check(str(error) == "invalid-setup-mode", "reject an unsupported setup mode")
else:
    check(False, "reject an unsupported setup mode")
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
            *((200, verified_page, page_url) for _ in range(3)),
        ],
    ) as read_page,
    redirect_stdout(io.StringIO()),
):
    smoke_result = SMOKE.run(None)

check(smoke_result == 0, "pass when normal and query-spoof requests retain the SSO account")
check(read_page.call_count == 5, "make landing, normal, and three separate spoofed requests")
for call, parameter in zip(read_page.call_args_list[2:], ("user", "username", "account")):
    query = parse_qs(urlsplit(call.args[1]).query)
    check(query == {parameter: ["root"]}, f"probe {parameter} independently")

with redirect_stdout(io.StringIO()):
    check(
        SMOKE.validate_spoof_accounts(["other", "third", "other"], "tester") == ["other", "third"],
        "deduplicate multiple requested accounts",
    )
for values, expected_error in ((["bad/name"], "invalid-spoof-account"), (["tester"], "spoof-account-must-differ")):
    try:
        SMOKE.validate_spoof_accounts(values, "tester")
    except ValueError as error:
        check(str(error) == expected_error, f"reject unsafe spoof target: {expected_error}")
    else:
        check(False, f"reject unsafe spoof target: {expected_error}")

with (
    patch.object(SMOKE.os, "geteuid", return_value=0, create=True),
    patch.object(SMOKE, "select_account", return_value="tester"),
    patch.object(SMOKE, "create_session_url", return_value="https://example.invalid/cpsess123/login"),
    patch.object(
        SMOKE,
        "read_page",
        side_effect=[(200, "", landing_url), *((200, verified_page, page_url) for _ in range(7))],
    ) as read_page,
    redirect_stdout(io.StringIO()),
):
    smoke_result = SMOKE.run(None, spoof_accounts=["other", "third"])
check(smoke_result == 0 and read_page.call_count == 8, "probe two accounts across all three identity parameters")
for index, expected_user in enumerate(("other", "third")):
    for call, parameter in zip(read_page.call_args_list[2 + index * 3 : 5 + index * 3], ("user", "username", "account")):
        check(parse_qs(urlsplit(call.args[1]).query) == {parameter: [expected_user]}, "use each requested spoof identity")

native_setup_page = "<h4>Native service readiness</h4><a>Back to setup choices</a>"
podman_setup_page = "<h4>cPanel EA Podman readiness</h4><a>Back to setup choices</a>"
with (
    patch.object(SMOKE.os, "geteuid", return_value=0, create=True),
    patch.object(SMOKE, "select_account", return_value="tester"),
    patch.object(SMOKE, "create_session_url", return_value="https://example.invalid/cpsess123/login"),
    patch.object(
        SMOKE,
        "read_page",
        side_effect=[
            (200, "", landing_url),
            (200, verified_page + first_run_page, page_url),
            (200, native_setup_page, SMOKE.setup_route_url(page_url, "native")),
            (200, podman_setup_page, SMOKE.setup_route_url(page_url, "podman")),
        ],
    ) as read_page,
    redirect_stdout(io.StringIO()),
):
    smoke_result = SMOKE.run(None, require_first_run_setup=True)
check(smoke_result == 0, "GET the default, native, and Podman first-run pages")
check(read_page.call_count == 4, "read the authenticated landing and three first-run setup pages")

print("Live cPanel smoke assertions passed: 32 checks.")
