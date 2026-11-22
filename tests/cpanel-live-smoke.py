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


def page_has_first_run_setup(body: str) -> bool:
    """Require the default first-run page to offer both backend choices."""
    return all(
        marker in body
        for marker in (
            'id="orm-setup-title">First-time setup',
            'href="?orm_setup=native"',
            'href="?orm_setup=podman"',
            "Native service",
            "cPanel EA Podman",
        )
    )


def setup_route_url(plugin_page_url: str, mode: str) -> str:
    """Build a fixed same-page GET route from the authenticated session URL."""
    if mode not in {"native", "podman"}:
        raise ValueError("invalid-setup-mode")
    parts = urllib.parse.urlsplit(plugin_page_url)
    if parts.scheme != "https" or not parts.netloc or "/frontend/jupiter/orm/index.live.php" not in parts.path:
        raise RuntimeError("setup-page-url-invalid")
    return urllib.parse.urlunsplit(
        (parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode({"orm_setup": mode}), "")
    )


def url_has_setup_mode(url: str, mode: str) -> bool:
    """Check that cPanel redirects preserve only the requested setup selector."""
    return urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).get("orm_setup") == [mode]


def page_has_setup_route(body: str, mode: str) -> bool:
    """Recognize a selected setup view without retaining its runtime findings."""
    if mode == "native":
        return "Native service readiness" in body and "Back to setup choices" in body
    if mode == "podman":
        return "cPanel EA Podman readiness" in body and "Back to setup choices" in body
    return False


def validate_spoof_accounts(accounts: list[str] | None, authenticated_user: str) -> list[str]:
    """Return distinct, safe account values that must not change SSO identity."""
    candidates = accounts if accounts else ["root"]
    if any(USERNAME.fullmatch(account) is None for account in candidates):
        raise ValueError("invalid-spoof-account")
    if any(account == authenticated_user for account in candidates):
        raise ValueError("spoof-account-must-differ")
    return list(dict.fromkeys(candidates))


def run(
    user: str | None,
    require_podman_cache: bool = False,
    require_first_run_setup: bool = False,
    spoof_accounts: list[str] | None = None,
) -> int:
    if os.geteuid() != 0:
        print("Run this check as root on the cPanel host.")
        return 2
    if require_podman_cache and require_first_run_setup:
        print("Choose either the existing Podman-cache check or the first-run setup check.")
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
        if not require_first_run_setup:
            parts = urllib.parse.urlsplit(target_url)
            for spoof_account in validate_spoof_accounts(spoof_accounts, account):
                for parameter in ("user", "username", "account"):
                    spoofed_query = urllib.parse.urlencode({parameter: spoof_account})
                    spoofed_url = urllib.parse.urlunsplit(
                        (parts.scheme, parts.netloc, parts.path, spoofed_query, parts.fragment)
                    )
                    spoofed_status, spoofed_body, _ = read_page(opener, spoofed_url)
                    if spoofed_status != 200 or not page_has_verified_account(spoofed_body, account):
                        print("The cPanel page identity changed or failed under account query-parameter spoofing.")
                        return 1
    except Exception as error:  # Keep URLs and account data out of diagnostics.
        print(f"Live cPanel smoke test failed ({type(error).__name__}).")
        return 1

    if "could not be verified by the local ORM broker" in body:
        print("The cPanel page loaded, but the broker identity check failed.")
        return 1
    if status != 200 or not page_has_verified_account(body, account):
        print(f"The ORM cPanel page did not verify the requested account identity (HTTP {status}).")
        return 1
    if require_podman_cache and not page_has_reachable_podman_cache(body):
        print("The cPanel identity check passed, but no reachable Podman cache was shown.")
        return 1
    if require_first_run_setup:
        if not page_has_first_run_setup(body):
            print("The authenticated account did not show both first-run backend choices.")
            return 1
        try:
            for mode in ("native", "podman"):
                route_status, route_body, final_url = read_page(opener, setup_route_url(target_url, mode))
                if route_status != 200:
                    print(f"The authenticated {mode} setup view returned HTTP {route_status}.")
                    return 1
                if not page_has_setup_route(route_body, mode):
                    query_preserved = url_has_setup_mode(final_url, mode)
                    choices_still_visible = page_has_first_run_setup(route_body)
                    identity_verified = page_has_verified_account(route_body, account)
                    section_heading = "Native service readiness" if mode == "native" else "cPanel EA Podman readiness"
                    heading_present = section_heading in route_body
                    back_link_present = "Back to setup choices" in route_body
                    print(
                        f"The authenticated {mode} setup view returned HTTP 200 without all expected markers "
                        f"(setup selector preserved: {'yes' if query_preserved else 'no'}; "
                        f"section heading: {'yes' if heading_present else 'no'}; "
                        f"back link: {'yes' if back_link_present else 'no'}; "
                        f"choice page still visible: {'yes' if choices_still_visible else 'no'}; "
                        f"account identity still rendered: {'yes' if identity_verified else 'no'})."
                    )
                    return 1
        except Exception as error:
            print(f"Live cPanel setup-route check failed ({type(error).__name__}).")
            return 1
        print("Live cPanel first-run choices and native/Podman setup views passed (GET only).")
        return 0
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
    parser.add_argument(
        "--require-first-run-setup",
        action="store_true",
        help="also GET the first-run choice, native, and Podman setup views for an unconfigured account with verified empty Podman inventory",
    )
    parser.add_argument(
        "--spoof-account",
        action="append",
        help="also try this account in each identity query parameter; may be repeated",
    )
    args = parser.parse_args()
    try:
        return run(
            args.user,
            require_podman_cache=args.require_podman_cache,
            require_first_run_setup=args.require_first_run_setup,
            spoof_accounts=args.spoof_account,
        )
    except ValueError as error:
        print("Provide one valid cPanel account with --user, or run on a single-account test host.")
        return 2


if __name__ == "__main__":
    sys.exit(main())
