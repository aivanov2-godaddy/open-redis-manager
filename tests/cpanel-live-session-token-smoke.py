#!/usr/bin/env python3
"""Verify cPanel and WHM reject authenticated POSTs without their cpsess token.

Run as root on a disposable cPanel & WHM host. The harness first checks the
installed plugin sources against the expected repository hashes, opens fresh
SSO sessions, and loads each plugin through its valid cpsess route. It then
sends an unsupported no-op action to each plugin over the same session cookies
but without the cpsess path token. Session URLs, cookies, account names, and
response bodies are kept in memory and never printed or written to disk.
"""

from __future__ import annotations

import argparse
import hashlib
import http.cookiejar
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing

CPANEL_ROOT = "/usr/local/cpanel"
WHMAPI1 = f"{CPANEL_ROOT}/bin/whmapi1"
CPANEL_PAGE = f"{CPANEL_ROOT}/base/frontend/jupiter/orm/index.live.php"
WHM_PAGE = f"{CPANEL_ROOT}/whostmgr/docroot/cgi/addon_open_redis_manager.php"
SESSION_GUARD = f"{CPANEL_ROOT}/3rdparty/orm/src/Orm/Security/SessionRequestGuard.php"
USERNAME = re.compile(r"\A[a-zA-Z0-9_-]{1,16}\Z")
SHA256 = re.compile(r"\A[a-f0-9]{64}\Z")
CPSESS = re.compile(r"\A/cpsess[0-9]{10}/")
MAX_BODY_BYTES = 4 * 1024 * 1024
TIMEOUT_SECONDS = 30
INVALID_ACTION = "orm-csrf-probe-unsupported"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def verify_source(path: str, expected_hash: str) -> None:
    if SHA256.fullmatch(expected_hash) is None:
        raise RuntimeError("expected-hash-invalid")
    try:
        with open(path, "rb") as source:
            digest = hashlib.sha256(source.read()).hexdigest()
    except OSError as error:
        raise RuntimeError("installed-source-unavailable") from error
    if digest != expected_hash:
        raise RuntimeError("installed-source-mismatch")


def create_session_url(username: str, service: str) -> str:
    result = subprocess.run(
        [WHMAPI1, "--output=json", "create_user_session", f"user={username}", f"service={service}"],
        capture_output=True,
        text=True,
        timeout=TIMEOUT_SECONDS,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("session-create-failed")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("session-response-invalid") from error
    url = payload.get("data", {}).get("url")
    if not isinstance(url, str):
        raise RuntimeError("session-url-missing")
    parts = urllib.parse.urlsplit(url)
    expected_port = 2083 if service == "cpaneld" else 2087
    if parts.scheme != "https" or not parts.hostname or parts.port != expected_port:
        raise RuntimeError("session-url-invalid")
    if parts.username is not None or parts.password is not None or parts.fragment:
        raise RuntimeError("session-url-invalid")
    return url


def open_page(opener: urllib.request.OpenerDirector, url: str) -> tuple[int, str, str]:
    try:
        response = opener.open(url, timeout=TIMEOUT_SECONDS)
    except urllib.error.HTTPError as error:
        response = error
    with closing(response):
        body = response.read(MAX_BODY_BYTES + 1)
        if len(body) > MAX_BODY_BYTES:
            raise RuntimeError("plugin-page-too-large")
        return response.code, body.decode("utf-8", "replace"), response.geturl()


def no_token_post_denied(
    opener: urllib.request.OpenerDirector, origin: str, path: str
) -> str | None:
    url = urllib.parse.urlunsplit(("https", origin, path, "", ""))
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode({"orm_action": INVALID_ACTION}).encode("ascii"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        response = opener.open(request, timeout=TIMEOUT_SECONDS)
    except urllib.error.HTTPError as error:
        response = error
    with closing(response):
        body = response.read(MAX_BODY_BYTES + 1)
        if len(body) > MAX_BODY_BYTES:
            raise RuntimeError("denial-response-too-large")
        text = body.decode("utf-8", "replace").lower()
        location = response.headers.get("Location", "").lower()
        denied_status = response.code in {401, 403}
        token_error = "invalid security token" in text or "msg_code:[invalid_token]" in text
        login_redirect = response.code in {301, 302, 303, 307, 308} and "login" in location
        if denied_status:
            return f"http-{response.code}"
        if token_error:
            return "invalid-token-page"
        if login_redirect:
            return "login-redirect"
        return None


def validate_service(username: str, service: str, plugin_path: str, no_token_path: str) -> str:
    landing_url = create_session_url(username, service)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    landing_status, _, landing = open_page(opener, landing_url)
    parts = urllib.parse.urlsplit(landing)
    if landing_status != 200 or parts.scheme != "https" or not parts.netloc:
        raise RuntimeError("sso-landing-failed")
    session_match = re.search(r"/(cpsess[0-9]{10})(?:/|$)", parts.path)
    if session_match is None:
        raise RuntimeError("sso-session-token-missing")
    tokenized_path = f"/{session_match.group(1)}{plugin_path}"
    plugin_url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, tokenized_path, "", ""))
    plugin_status, _, plugin_final_url = open_page(opener, plugin_url)
    final = urllib.parse.urlsplit(plugin_final_url)
    if plugin_status != 200 or final.netloc != parts.netloc or CPSESS.match(final.path) is None:
        raise RuntimeError("valid-token-plugin-route-failed")

    no_redirect = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar), NoRedirect()
    )
    denial = no_token_post_denied(no_redirect, parts.netloc, no_token_path)
    if denial is None:
        raise RuntimeError("no-token-post-not-denied")
    return denial


def run(args: argparse.Namespace) -> int:
    if os.geteuid() != 0 or sys.platform != "linux":
        raise RuntimeError("root-linux-required")
    if USERNAME.fullmatch(args.cpanel_user) is None:
        raise RuntimeError("account-invalid")

    verify_source(CPANEL_PAGE, args.cpanel_page_sha256)
    verify_source(WHM_PAGE, args.whm_page_sha256)
    verify_source(SESSION_GUARD, args.guard_sha256)

    cpanel_denial = validate_service(
        args.cpanel_user,
        "cpaneld",
        "/frontend/jupiter/orm/index.live.php",
        "/frontend/jupiter/orm/index.live.php",
    )
    whm_denial = validate_service(
        "root",
        "whostmgrd",
        "/cgi/addon_open_redis_manager.php",
        "/cgi/addon_open_redis_manager.php",
    )
    print(
        "Source-matched cPanel and WHM sessions accepted valid cpsess routes; "
        f"no-token POSTs were rejected ({cpanel_denial}, {whm_denial})."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpanel-user", required=True, help="disposable cPanel account username")
    parser.add_argument("--cpanel-page-sha256", required=True)
    parser.add_argument("--whm-page-sha256", required=True)
    parser.add_argument("--guard-sha256", required=True)
    try:
        return run(parser.parse_args())
    except Exception as error:  # Never print URLs, credentials, account names, or response bodies.
        reason = error.args[0] if isinstance(error, RuntimeError) and error.args else "error"
        if not isinstance(reason, str) or re.fullmatch(r"[a-z-]{1,64}", reason) is None:
            reason = "error"
        print(f"Live session-token smoke test failed ({type(error).__name__}:{reason}).")
        return 1


if __name__ == "__main__":
    sys.exit(main())
