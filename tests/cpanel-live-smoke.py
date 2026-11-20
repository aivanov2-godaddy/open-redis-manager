#!/usr/bin/env python3
"""Read-only live check for an installed ORM cPanel entry point.

Run as root on a disposable cPanel & WHM host. The SSO URL and account name
stay in memory and are never printed or written to disk.
"""

from __future__ import annotations

import argparse
import html
import http.cookiejar
import json
import os
import re
import subprocess
import sys
from contextlib import closing
import urllib.error
import urllib.parse
import urllib.request

USERNAME = re.compile(r"\A[a-zA-Z0-9_-]{1,16}\Z")
USERS_DIR = "/var/cpanel/users"
WHMAPI1 = "/usr/local/cpanel/bin/whmapi1"
LOGIN_TIMEOUT_SECONDS = 20
MAX_PAGE_BYTES = 256 * 1024
PODMAN_SECTION = re.compile(
    r'<section\b[^>]*aria-labelledby=["\']orm-podman-title["\'][^>]*>.*?</section>',
    re.IGNORECASE | re.DOTALL,
)
REACHABLE_STATUS = re.compile(r'<strong>\s*Status:\s*</strong>\s*Reachable\b', re.IGNORECASE)
VERIFIED_ACCOUNT = re.compile(
    r'<p\b[^>]*>\s*Verified cPanel account:\s*<code\b[^>]*>([^<]*)</code>\s*</p>',
    re.IGNORECASE,
)


def select_account(user: str | None) -> str:
    """Return an explicit, syntactically safe cPanel account name."""
    if user is not None:
        if USERNAME.fullmatch(user) is None:
            raise ValueError("invalid-account")
        return user

    with os.scandir(USERS_DIR) as entries:
        accounts = [
            entry.name
            for entry in entries
            if USERNAME.fullmatch(entry.name) is not None and entry.is_file(follow_symlinks=False)
        ]
    if len(accounts) != 1 or USERNAME.fullmatch(accounts[0]) is None:
        raise ValueError("select-one-account")
    return accounts[0]


def create_session_url(user: str) -> str:
    result = subprocess.run(
        [WHMAPI1, "create_user_session", f"user={user}", "service=cpaneld", "--output=json"],
        check=False,
        capture_output=True,
        text=True,
        timeout=LOGIN_TIMEOUT_SECONDS,
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
    if parts.scheme != "https" or not parts.netloc:
        raise RuntimeError("session-url-invalid")
    return url


def plugin_url(landing_url: str) -> str:
    parts = urllib.parse.urlsplit(landing_url)
    match = re.search(r"/(cpsess[^/]+)(?:/|$)", parts.path)
    if parts.scheme != "https" or not parts.netloc or match is None:
        raise RuntimeError("session-redirect-invalid")
    path = f"/{match.group(1)}/frontend/jupiter/orm/index.live.php"
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, "", ""))


def read_page(opener: urllib.request.OpenerDirector, url: str) -> tuple[int, str, str]:
    try:
        with closing(opener.open(url, timeout=LOGIN_TIMEOUT_SECONDS)) as response:
            body = response.read(MAX_PAGE_BYTES).decode("utf-8", "replace")
            return response.status, body, response.geturl()
    except urllib.error.HTTPError as error:
        with closing(error):
            body = error.read(MAX_PAGE_BYTES).decode("utf-8", "replace")
            return error.code, body, error.geturl()


def page_has_reachable_podman_cache(body: str) -> bool:
    """Return whether the account page reports a reachable cPanel-managed cache."""
    match = PODMAN_SECTION.search(body)
    return match is not None and REACHABLE_STATUS.search(match.group(0)) is not None


def page_has_verified_account(body: str, expected_user: str) -> bool:
    """Require the page's displayed LiveAPI identity to match the SSO account."""
    match = VERIFIED_ACCOUNT.search(body)
    return match is not None and html.unescape(match.group(1)) == expected_user


def run(user: str | None, require_podman_cache: bool = False) -> int:
    if os.geteuid() != 0:
        print("Run this check as root on the cPanel host.")
        return 2

    try:
        account = select_account(user)
        login_url = create_session_url(account)
        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )
        _, _, landing_url = read_page(opener, login_url)
        target_url = plugin_url(landing_url)
        status, body, _ = read_page(opener, target_url)
        parts = urllib.parse.urlsplit(target_url)
        spoofed_query = urllib.parse.urlencode({"user": "root", "username": "root", "account": "root"})
        spoofed_url = urllib.parse.urlunsplit(
            (parts.scheme, parts.netloc, parts.path, spoofed_query, parts.fragment)
        )
        spoofed_status, spoofed_body, _ = read_page(opener, spoofed_url)
    except Exception as error:  # Keep URLs and account data out of diagnostics.
        print(f"Live cPanel smoke test failed ({type(error).__name__}).")
        return 1

    if "could not be verified by the local ORM broker" in body:
        print("The cPanel page loaded, but the broker identity check failed.")
        return 1
    if status != 200 or not page_has_verified_account(body, account):
        print(f"The ORM cPanel page did not verify the requested account identity (HTTP {status}).")
        return 1
    if spoofed_status != 200 or not page_has_verified_account(spoofed_body, account):
        print("The cPanel page identity changed or failed under account query-parameter spoofing.")
        return 1

    if require_podman_cache and not page_has_reachable_podman_cache(body):
        print("The cPanel identity check passed, but no reachable Podman cache was shown.")
        return 1
    if require_podman_cache:
        print("Live cPanel account identity, query-spoof, and Podman cache checks passed.")
        return 0
    print("Live cPanel account identity and query-spoof checks passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", help="cPanel username; omit only when exactly one account exists")
    parser.add_argument(
        "--require-podman-cache",
        action="store_true",
        help="also require the authenticated page to show a reachable cPanel-managed Redis/Valkey socket",
    )
    args = parser.parse_args()
    try:
        return run(args.user, require_podman_cache=args.require_podman_cache)
    except ValueError as error:
        print("Provide one valid cPanel account with --user, or run on a single-account test host.")
        return 2


if __name__ == "__main__":
    sys.exit(main())
