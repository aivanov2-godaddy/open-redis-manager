#!/usr/bin/env python3
"""Read-only live check for an installed ORM cPanel entry point.

Run as root on a disposable cPanel & WHM host. The SSO URL and account name
stay in memory and are never printed or written to disk.
"""

from __future__ import annotations

import argparse
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


def run(user: str | None) -> int:
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
    except Exception as error:  # Keep URLs and account data out of diagnostics.
        print(f"Live cPanel smoke test failed ({type(error).__name__}).")
        return 1

    if status == 200 and "Verified cPanel account:" in body:
        print("Live cPanel account identity check passed.")
        return 0
    if "could not be verified by the local ORM broker" in body:
        print("The cPanel page loaded, but the broker identity check failed.")
        return 1
    print(f"The ORM cPanel page returned an unexpected response (HTTP {status}).")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", help="cPanel username; omit only when exactly one account exists")
    args = parser.parse_args()
    try:
        return run(args.user)
    except ValueError as error:
        print("Provide one valid cPanel account with --user, or run on a single-account test host.")
        return 2


if __name__ == "__main__":
    sys.exit(main())
