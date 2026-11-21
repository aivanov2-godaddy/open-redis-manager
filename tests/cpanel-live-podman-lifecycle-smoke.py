#!/usr/bin/env python3
"""Authenticated cPanel SSO smoke for the account-owned EA Podman controls.

Run as root on a disposable cPanel host. This check starts, stops, and restarts
one Redis/Valkey container rendered for the selected account, verifies each
result through the account page, and restores the container's initial
running/stopped state. Pass --backend when the account has multiple backends.
The account, session URL, container ID, socket path, and page body stay in
memory and are never printed or written to disk.
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
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing

USERNAME = re.compile(r"\A[a-zA-Z0-9_-]{1,16}\Z")
WHMAPI1 = "/usr/local/cpanel/bin/whmapi1"
USERS_DIR = "/var/cpanel/users"
TIMEOUT_SECONDS = 20
MAX_PAGE_BYTES = 512 * 1024
PODMAN_SECTION = re.compile(
    r'<section\b[^>]*aria-labelledby=["\']orm-podman-title["\'][^>]*>.*?</section>',
    re.IGNORECASE | re.DOTALL,
)
CONTAINER = re.compile(
    r'<input\b(?=[^>]*\bname=["\']orm_podman_container["\'])'
    r'(?=[^>]*\bvalue=["\']([^"\']+)["\'])[^>]*>', re.IGNORECASE,
)
CACHE_CARD = re.compile(r'<article\b[^>]*>.*?</article>', re.IGNORECASE | re.DOTALL)
STATUS = re.compile(r'<strong>\s*Status:\s*</strong>\s*([^<·]+)', re.IGNORECASE)
VERIFIED_ACCOUNT = re.compile(
    r'<p\b[^>]*>\s*Verified cPanel account:\s*<code\b[^>]*>([^<]*)</code>\s*</p>',
    re.IGNORECASE,
)
ACTION_SUCCESS = "The cPanel container action completed."


class CpanelSessionRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follow only HTTPS redirects that remain on the same host and session."""

    def redirect_request(self, request, response, code, message, headers, new_url):
        old = urllib.parse.urlsplit(request.full_url)
        target = urllib.parse.urlsplit(urllib.parse.urljoin(request.full_url, new_url))
        match = re.match(r"\A/(cpsess[0-9]{10})(?:/|\Z)", old.path)
        if match is None:
            raise urllib.error.HTTPError(request.full_url, code, "invalid session redirect", headers, response)
        prefix = "/" + match.group(1)
        decoded_path = urllib.parse.unquote(target.path)
        same_origin = (target.scheme == "https" and old.scheme == "https"
                       and (target.hostname or "").lower() == (old.hostname or "").lower()
                       and (target.port or 443) == (old.port or 443))
        same_session = target.path == prefix or target.path.startswith(prefix + "/")
        safe_path = "\\" not in decoded_path and not set(decoded_path.split("/")) & {".", ".."}
        if not same_origin or not same_session or not safe_path or target.username or target.password:
            raise urllib.error.HTTPError(request.full_url, code, "redirect outside cPanel session", headers, response)
        return super().redirect_request(request, response, code, message, headers, new_url)


def parse_cache(body: str, backend: str | None = None) -> tuple[str, str] | None:
    """Return one unambiguous page-rendered container and its sanitized status."""
    if backend not in {None, "redis", "valkey"}:
        return None
    section = PODMAN_SECTION.search(body)
    if section is None:
        return None
    matches: list[tuple[str, str]] = []
    for card in CACHE_CARD.findall(section.group(0)):
        container = CONTAINER.search(card)
        status = STATUS.search(card)
        if container is None or status is None:
            continue
        identifier = html.unescape(container.group(1))
        if re.fullmatch(r"ea-(?:redis|valkey)[a-zA-Z0-9._-]{1,96}", identifier) is None:
            continue
        actual_backend = "redis" if identifier.startswith("ea-redis") else "valkey"
        if backend is not None and actual_backend != backend:
            continue
        state = " ".join(status.group(1).strip().lower().split())
        matches.append((identifier, state))
    if len(matches) != 1 or matches[0][1] not in {"reachable", "socket missing"}:
        return None
    return matches[0]


def page_diagnostic(body: str, backend: str | None = None) -> str:
    """Return only fixed structural/state labels, never page data."""
    if backend not in {None, "redis", "valkey"}:
        return "podman_status_missing"
    section = PODMAN_SECTION.search(body)
    if section is None:
        return "podman_section_missing"
    states: list[str] = []
    for card in CACHE_CARD.findall(section.group(0)):
        container = CONTAINER.search(card)
        state = STATUS.search(card)
        if container is None or state is None:
            continue
        identifier = html.unescape(container.group(1))
        actual_backend = "redis" if identifier.startswith("ea-redis") else "valkey"
        if backend is not None and actual_backend != backend:
            continue
        states.append(state.group(1))
    if len(states) != 1:
        return "podman_status_missing"
    label = " ".join(states[0].strip().lower().split())
    if label not in {"reachable", "socket missing", "unavailable", "not checked"}:
        label = "other"
    return "podman_status_" + label.replace(" ", "_")


def lifecycle_sequence(initial: str) -> list[tuple[str, str]]:
    """Return only fixed actions that restore the initial state."""
    if initial == "reachable":
        return [("stop", "socket missing"), ("start", "reachable"),
                ("restart", "reachable")]
    if initial == "socket missing":
        return [("start", "reachable"), ("restart", "reachable"),
                ("stop", "socket missing")]
    raise ValueError("unsupported-initial-state")


def select_account(user: str) -> str:
    if USERNAME.fullmatch(user) is None or not os.path.isfile(os.path.join(USERS_DIR, user)):
        raise ValueError("invalid-account")
    return user


def page_has_verified_account(body: str, expected_user: str) -> bool:
    match = VERIFIED_ACCOUNT.search(body)
    return match is not None and html.unescape(match.group(1)) == expected_user


def container_belongs_to_user(container: str, user: str) -> bool:
    return re.fullmatch(
        rf"ea-(?:redis|valkey)[0-9]{{2,4}}\.{re.escape(user)}\.[0-9]{{2,3}}", container
    ) is not None


def create_session_url(user: str) -> str:
    result = subprocess.run(
        [WHMAPI1, "create_user_session", f"user={user}", "service=cpaneld", "--output=json"],
        check=False, capture_output=True, text=True, timeout=TIMEOUT_SECONDS,
    )
    if result.returncode != 0:
        raise RuntimeError("session-create-failed")
    try:
        payload = json.loads(result.stdout)
        url = payload["data"]["url"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise RuntimeError("session-response-invalid") from error
    parts = urllib.parse.urlsplit(url) if isinstance(url, str) else None
    if parts is None or parts.scheme != "https" or not parts.netloc \
            or parts.username is not None or parts.password is not None or parts.fragment \
            or parts.port not in (None, 2083) \
            or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", parts.hostname or "") \
            or re.fullmatch(r"/cpsess[0-9]{10}/login/?", parts.path) is None or not parts.query:
        raise RuntimeError("session-url-invalid")
    return url


def plugin_url(landing_url: str) -> str:
    parts = urllib.parse.urlsplit(landing_url)
    match = re.search(r"/(cpsess[0-9]{10})(?:/|$)", parts.path)
    if parts.scheme != "https" or not parts.netloc or match is None:
        raise RuntimeError("session-redirect-invalid")
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc,
        f"/{match.group(1)}/frontend/jupiter/orm/index.live.php", "", ""))


def read_response(response) -> tuple[int, str, str]:
    with closing(response):
        body = response.read(MAX_PAGE_BYTES + 1)
        if len(body) > MAX_PAGE_BYTES:
            raise RuntimeError("page-too-large")
        return response.status, body.decode("utf-8", "replace"), response.geturl()


def request_page(opener: urllib.request.OpenerDirector, url: str,
                 action: str | None = None, container: str | None = None) -> tuple[int, str, str]:
    if action is None:
        request = urllib.request.Request(url, headers={"Accept": "text/html"})
    else:
        if action not in {"start", "stop", "restart"} or container is None:
            raise ValueError("invalid-action")
        form = urllib.parse.urlencode({"orm_podman_action": action,
            "orm_podman_container": container}).encode("ascii")
        parts = urllib.parse.urlsplit(url)
        origin = urllib.parse.urlunsplit((parts.scheme, parts.netloc, "", "", ""))
        request = urllib.request.Request(url, data=form, headers={
            "Accept": "text/html", "Content-Type": "application/x-www-form-urlencoded",
            "Origin": origin, "Referer": url,
        })
    try:
        return read_response(opener.open(request, timeout=TIMEOUT_SECONDS))
    except urllib.error.HTTPError as error:
        return read_response(error)


def verified_page(opener: urllib.request.OpenerDirector, url: str,
                  expected_user: str) -> tuple[int, str]:
    status, body, final_url = request_page(opener, url)
    expected = urllib.parse.urlsplit(url)
    final = urllib.parse.urlsplit(final_url)
    identity = VERIFIED_ACCOUNT.search(body)
    if status != 200 or (expected.scheme, expected.netloc, expected.path) != (
            final.scheme, final.netloc, final.path) or identity is None \
            or html.unescape(identity.group(1)) != expected_user:
        raise RuntimeError("authenticated-page-verification-failed")
    return status, body


def wait_for_state(opener: urllib.request.OpenerDirector, url: str, account: str,
                   container: str, expected_state: str, backend: str | None = None) -> str:
    last_diagnostic = "page_unavailable"
    for attempt in range(21):
        _, body = verified_page(opener, url, account)
        last_diagnostic = page_diagnostic(body, backend)
        if parse_cache(body, backend) == (container, expected_state):
            return body
        if attempt < 20:
            time.sleep(1)
    raise RuntimeError("state-verification-failed:" + last_diagnostic)


def run(user: str, confirmed: bool, backend: str | None = None) -> int:
    if not confirmed:
        print("Pass --confirm-lifecycle to run the account-owned start/stop/restart smoke.")
        return 2
    if os.geteuid() != 0 or not os.path.isfile(WHMAPI1):
        print("Run this check as root on a cPanel host.")
        return 2
    opener: urllib.request.OpenerDirector | None = None
    target: str | None = None
    account: str | None = None
    container: str | None = None
    initial_state: str | None = None
    failure: Exception | None = None
    restoration_failed = False
    restoration_detail = ""
    post_diagnostics = "unavailable"
    phase = "account-selection"
    try:
        account = select_account(user)
        opener = urllib.request.build_opener(
            CpanelSessionRedirectHandler(),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        phase = "sso-session"
        _, _, landing = request_page(opener, create_session_url(account))
        target = plugin_url(landing)
        phase = "initial-page"
        _, body = verified_page(opener, target, account)
        initial_cache = parse_cache(body, backend)
        if initial_cache is None:
            raise RuntimeError("no-single-healthy-podman-cache")
        container, initial_state = initial_cache
        if not container_belongs_to_user(container, account):
            raise RuntimeError("cache-owner-mismatch")
        for action, expected_state in lifecycle_sequence(initial_state):
            phase = "post-" + action
            code, response, final_url = request_page(opener, target, action, container)
            same_path = urllib.parse.urlsplit(final_url).path == urllib.parse.urlsplit(target).path
            post_diagnostics = (
                f"http_{code};same_path_{'yes' if same_path else 'no'};"
                f"success_message_{'yes' if ACTION_SUCCESS in response else 'no'};"
                f"failure_message_{'yes' if 'The container action could not be completed.' in response else 'no'};"
                f"identity_{'yes' if page_has_verified_account(response, account) else 'no'}"
            )
            if code != 200 or not same_path:
                raise RuntimeError("lifecycle-post-failed")
            phase = "verify-" + action
            refreshed = wait_for_state(opener, target, account, container, expected_state, backend)
        final_cache = parse_cache(refreshed, backend)
        if final_cache is None or final_cache[1] != initial_state:
            raise RuntimeError("initial-state-not-restored")
    except Exception as error:  # Never reveal account, URL, container, socket, or response details.
        failure = error
        if opener is not None and target is not None and account is not None \
                and container is not None and initial_state is not None:
            try:
                _, current_body = verified_page(opener, target, account)
                current = parse_cache(current_body, backend)
                if current is None or current[0] != container:
                    restoration_failed = True
                    restoration_detail = page_diagnostic(current_body, backend)
                elif current[1] != initial_state:
                    restore_action = "start" if initial_state == "reachable" else "stop"
                    code, _, _ = request_page(opener, target, restore_action, container)
                    if code != 200:
                        restoration_failed = True
                    else:
                        try:
                            wait_for_state(opener, target, account, container, initial_state, backend)
                        except Exception as restore_error:
                            restoration_failed = True
                            restoration_detail = type(restore_error).__name__
            except Exception:
                restoration_failed = True
                if not restoration_detail:
                    restoration_detail = "restore_page_failed"
    if failure is not None:
        detail = "; initial state restoration failed" if restoration_failed else ""
        diagnostic = f"; {post_diagnostics}" if phase.startswith("post-") else ""
        if phase.startswith("verify-") and isinstance(failure, RuntimeError):
            suffix = str(failure).split(":", 1)[-1]
            if suffix.startswith("podman_") or suffix == "page_unavailable":
                diagnostic = "; " + suffix
        if restoration_failed and restoration_detail:
            detail += "; " + restoration_detail
        print(f"Live cPanel Podman lifecycle smoke failed at {phase} ({type(failure).__name__})"
              f"{diagnostic}{detail}.")
        return 1
    target_label = f"{backend} backend" if backend is not None else "single discovered backend"
    print(f"Live cPanel Podman lifecycle passed for {target_label}: authenticated page, fixed action POSTs, state checks, initial state restored.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", required=True, help="cPanel account that owns the disposable Podman cache")
    parser.add_argument("--confirm-lifecycle", action="store_true",
                        help="allow the smoke to stop/restart the account-owned cache")
    parser.add_argument("--backend", choices=("redis", "valkey"),
                        help="require exactly one healthy cache of this backend")
    args = parser.parse_args()
    try:
        return run(args.user, args.confirm_lifecycle, args.backend)
    except ValueError:
        print("Provide a valid cPanel account name.")
        return 2


if __name__ == "__main__":
    sys.exit(main())
