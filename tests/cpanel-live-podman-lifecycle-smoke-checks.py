#!/usr/bin/env python3
"""Offline assertions for the authenticated cPanel Podman lifecycle smoke."""

from __future__ import annotations

import importlib.util
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "cpanel_live_podman_lifecycle_smoke",
    Path(__file__).with_name("cpanel-live-podman-lifecycle-smoke.py"),
)
assert SPEC is not None and SPEC.loader is not None
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


section = '''<section aria-labelledby="orm-podman-title">
<input type="hidden" name="orm_podman_container" value="ea-redis62.example.01">
<strong>Status:</strong> Reachable</section>'''
check(SMOKE.parse_cache(section) == ("ea-redis62.example.01", "reachable"),
      "parse only the authenticated page's supported account cache")
check(SMOKE.page_diagnostic(section) == "podman_status_reachable",
      "return only a fixed page-state diagnostic")
check(SMOKE.page_diagnostic("<html>") == "podman_section_missing",
      "identify absent Podman content without exposing page markup")
redirects = SMOKE.CpanelSessionRedirectHandler()
old_request = SMOKE.urllib.request.Request(
    "https://example.invalid/cpsess1234567890/login")
allowed = redirects.redirect_request(old_request, None, 302, "Found", {},
    "https://example.invalid/cpsess1234567890/frontend/jupiter/index.html")
check(allowed is not None, "follow redirects within the same HTTPS cPanel session")
for destination in (
    "https://outside.invalid/cpsess1234567890/frontend/jupiter/index.html",
    "https://example.invalid/cpsess9999999999/frontend/jupiter/index.html",
    "http://example.invalid/cpsess1234567890/frontend/jupiter/index.html",
):
    try:
        redirects.redirect_request(old_request, None, 302, "Found", {}, destination)
    except SMOKE.urllib.error.HTTPError:
        continue
    raise AssertionError("reject redirects that leave the HTTPS origin/session")
check(SMOKE.parse_cache(section.replace("ea-redis62.example.01", "ea-redis62.other.01"))
      == ("ea-redis62.other.01", "reachable"), "cache IDs remain opaque page input")
check(SMOKE.container_belongs_to_user("ea-redis62.example.01", "example"),
      "only operate on containers named for the selected account")
check(not SMOKE.container_belongs_to_user("ea-redis62.other.01", "example"),
      "refuse a page-rendered container owned by a different account")
check(SMOKE.parse_cache(section.replace("Status:</strong> Reachable", "Status:</strong> Socket missing"))
      == ("ea-redis62.example.01", "socket missing"), "recognize stopped containers")
check(SMOKE.parse_cache(section.replace("ea-redis62.example.01", "../unsafe")) is None,
      "reject malformed container IDs")
check(SMOKE.parse_cache(section.replace("Reachable", "Unavailable")) is None,
      "refuse unhealthy starting states")
check(SMOKE.lifecycle_sequence("reachable") == [
    ("stop", "socket missing"), ("start", "reachable"), ("restart", "reachable")],
      "exercise fixed actions and restore an initially running service")
check(SMOKE.lifecycle_sequence("socket missing") == [
    ("start", "reachable"), ("restart", "reachable"), ("stop", "socket missing")],
      "exercise all fixed actions and restore an initially stopped service")
try:
    SMOKE.lifecycle_sequence("unavailable")
except ValueError:
    pass
else:
    raise AssertionError("unhealthy state must not authorize mutations")
print("cPanel live Podman lifecycle smoke assertions passed: 16")
