#!/usr/bin/env python3
"""Probe cross-account authorization for the cPanel EA Podman lifecycle form.

Run as root on a disposable cPanel host with two accounts that each own exactly
one reachable EA Podman Redis/Valkey container. The check submits a foreign
container stop as the first plugin request in each sequential cPanel SSO session
and checks both Unix sockets with owner-context Redis PINGs. Identifiers, session
URLs, cookies, socket paths, command output, and page content are never printed
or written to disk.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import stat
import subprocess
import sys
import time
import urllib.parse
from http.cookiejar import CookieJar
from pathlib import Path
from urllib.request import HTTPCookieProcessor, build_opener

SPEC = importlib.util.spec_from_file_location(
    "cpanel_live_podman_lifecycle_smoke",
    Path(__file__).with_name("cpanel-live-podman-lifecycle-smoke.py"),
)
assert SPEC is not None and SPEC.loader is not None
LIFECYCLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LIFECYCLE)

RUNUSER = "/usr/sbin/runuser"
EA_PODMAN = "/usr/local/cpanel/scripts/ea-podman"
FAILURE_MESSAGE = "The container action could not be completed."
OWNER_PING_PROGRAM = (
    "import socket,sys\n"
    "s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)\n"
    "s.settimeout(4)\n"
    "s.connect(sys.argv[1])\n"
    "s.sendall(b'*1\\r\\n$4\\r\\nPING\\r\\n')\n"
    "reply=s.recv(64)\n"
    "s.close()\n"
    "sys.exit(0 if reply == b'+PONG\\r\\n' else 1)\n"
)


class NoFollowCpanelRedirectHandler(LIFECYCLE.CpanelSessionRedirectHandler):
    """Keep the original POST response so redirects cannot hide its result."""

    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def parse_ea_podman_output(output: str) -> dict[str, object]:
    """Parse the JSON object while tolerating fixed warnings before it."""
    start = output.find("{")
    if start < 0:
        raise RuntimeError("container-discovery-response-invalid")
    try:
        payload, end = json.JSONDecoder().raw_decode(output[start:])
    except json.JSONDecodeError as error:
        raise RuntimeError("container-discovery-response-invalid") from error
    if output[start + end:].strip() or not isinstance(payload, dict):
        raise RuntimeError("container-discovery-response-invalid")
    return payload


def owned_container_id(payload: object, username: str) -> str:
    """Return the sole account-owned Redis/Valkey container from EA Podman."""
    if not isinstance(payload, dict):
        raise RuntimeError("container-discovery-response-invalid")
    containers: list[str] = []
    for key, details in payload.items():
        if not isinstance(key, str) or not isinstance(details, dict):
            continue
        container = details.get("container_name", key)
        if details.get("user") != username or not isinstance(container, str):
            continue
        if not container.startswith(("ea-redis", "ea-valkey")):
            continue
        if container != key or not LIFECYCLE.container_belongs_to_user(container, username):
            raise RuntimeError("owned-container-identity-invalid")
        containers.append(container)
    if len(containers) != 1:
        raise RuntimeError("one-owned-container-required")
    return containers[0]


def container_socket_name(container: str) -> str:
    """Map a validated EA Redis/Valkey name to its fixed Unix socket name."""
    if container.startswith("ea-redis"):
        return "redis.sock"
    if container.startswith("ea-valkey"):
        return "valkey.sock"
    raise ValueError("unsupported-container")


def socket_is_owned_and_private(mode: int, socket_uid: int, expected_uid: int) -> bool:
    """Match ORM's socket rule: account-owned Unix socket, no world access."""
    return (
        stat.S_ISSOCK(mode)
        and socket_uid == expected_uid
        and mode & 0o007 == 0
    )


def run_as_owner(username: str, arguments: list[str]) -> subprocess.CompletedProcess[str]:
    """Execute a fixed command with the selected account's safe environment."""
    import pwd

    LIFECYCLE.select_account(username)
    account = pwd.getpwnam(username)
    return subprocess.run(
        [
            RUNUSER, "-u", username, "--", "/usr/bin/env",
            f"HOME={account.pw_dir}", f"USER={username}", f"LOGNAME={username}",
            "PATH=/usr/local/bin:/usr/bin:/bin", *arguments,
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=LIFECYCLE.TIMEOUT_SECONDS,
    )


def discover_owned_container(username: str) -> dict[str, object]:
    """Discover and validate the account's single EA Podman cache and socket."""
    import pwd

    account = pwd.getpwnam(username)
    result = run_as_owner(username, [EA_PODMAN, "containers"])
    if result.returncode != 0:
        raise RuntimeError("container-discovery-failed")
    container = owned_container_id(parse_ea_podman_output(result.stdout), username)
    home = Path(account.pw_dir)
    socket_path = home / "ea-podman.d" / container / container_socket_name(container)
    for directory in (home, home / "ea-podman.d", home / "ea-podman.d" / container):
        try:
            info = os.lstat(directory)
        except OSError as error:
            raise RuntimeError("owned-socket-directory-invalid") from error
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != account.pw_uid
            or info.st_mode & 0o022
            or os.path.realpath(directory) != str(directory)
        ):
            raise RuntimeError("owned-socket-directory-invalid")
    try:
        socket_info = os.lstat(socket_path)
    except OSError as error:
        raise RuntimeError("owned-socket-not-reachable") from error
    if not socket_is_owned_and_private(
        socket_info.st_mode, socket_info.st_uid, account.pw_uid
    ):
        raise RuntimeError("owned-socket-owner-invalid")
    return {
        "username": username,
        "uid": account.pw_uid,
        "container": container,
        "socket": str(socket_path),
    }


def owner_ping(record: dict[str, object]) -> bool:
    """Run a bounded Redis PING through the socket as its owning cPanel user."""
    try:
        result = run_as_owner(
            str(record["username"]),
            [sys.executable, "-c", OWNER_PING_PROGRAM, str(record["socket"])],
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0 and not result.stdout.strip()


def owner_start(record: dict[str, object]) -> bool:
    """Restore a stopped fixture only through its own cPanel account context."""
    try:
        result = run_as_owner(
            str(record["username"]),
            [EA_PODMAN, "start", str(record["container"])],
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def wait_for_owner_ping(record: dict[str, object], timeout: int = 15) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() <= deadline:
        if owner_ping(record):
            return True
        time.sleep(1)
    return False


def stable_owner_ping(record: dict[str, object], samples: int = 3) -> bool:
    """Require repeated successful owner PINGs across a short settling window."""
    for attempt in range(samples):
        if not owner_ping(record):
            return False
        if attempt + 1 < samples:
            time.sleep(1)
    return True


def restore_reachable(records: list[dict[str, object]]) -> bool:
    """Recover any affected fixture with its owner's start command, then PING."""
    restored = True
    for record in records:
        if owner_ping(record):
            continue
        owner_start(record)
        restored = wait_for_owner_ping(record) and restored
    return restored


def first_action_session(record: dict[str, object]) -> dict[str, object]:
    """Create one SSO session without consuming it on a plugin-page GET."""
    username = str(record["username"])
    LIFECYCLE.select_account(username)
    cookies = CookieJar()
    opener = build_opener(
        LIFECYCLE.CpanelSessionRedirectHandler(),
        HTTPCookieProcessor(cookies),
    )
    _, _, landing = LIFECYCLE.request_page(opener, LIFECYCLE.create_session_url(username))
    target = LIFECYCLE.plugin_url(landing)
    return {
        "username": username,
        "opener": opener,
        "target": target,
        "cookies": cookies,
        "container": record["container"],
        "record": record,
    }


def same_target(response_url: str, target_url: str) -> bool:
    response = urllib.parse.urlsplit(response_url)
    target = urllib.parse.urlsplit(target_url)
    return (response.scheme, response.netloc, response.path) == (
        target.scheme, target.netloc, target.path
    )


def foreign_action_denied(
    status: int,
    body: str,
    response_url: str,
    target_url: str,
    source_container: str,
    foreign_container: str,
    source_identity_verified: bool,
) -> bool:
    response_denied = status == 200 and FAILURE_MESSAGE in body
    return (
        response_denied
        and source_identity_verified
        and LIFECYCLE.PODMAN_SECTION.search(body) is not None
        and source_container in body
        and same_target(response_url, target_url)
        and LIFECYCLE.ACTION_SUCCESS not in body
        and foreign_container not in body
    )


def post_foreign_stop(source: dict[str, object], foreign: dict[str, object]):
    """Post the fixed stop action without following a possible PRG redirect."""
    opener = build_opener(
        NoFollowCpanelRedirectHandler(), HTTPCookieProcessor(source["cookies"])
    )
    target = str(source["target"])
    container = str(foreign["container"])
    form = urllib.parse.urlencode({
        "orm_podman_action": "stop", "orm_podman_container": container,
    }).encode("ascii")
    parts = urllib.parse.urlsplit(target)
    origin = urllib.parse.urlunsplit((parts.scheme, parts.netloc, "", "", ""))
    request = LIFECYCLE.urllib.request.Request(target, data=form, headers={
        "Accept": "text/html", "Content-Type": "application/x-www-form-urlencoded",
        "Origin": origin, "Referer": target,
    })
    try:
        response = opener.open(request, timeout=LIFECYCLE.TIMEOUT_SECONDS)
        status, body, final_url = LIFECYCLE.read_response(response)
    except LIFECYCLE.urllib.error.HTTPError as error:
        status, body, final_url = LIFECYCLE.read_response(error)
    return status, body, final_url


def probe(source: dict[str, object], foreign: dict[str, object]) -> tuple[bool, str]:
    """Try a foreign stop and require identity, explicit denial, and live sockets."""
    code, body, final_url = post_foreign_stop(source, foreign)
    source_identity = LIFECYCLE.page_has_verified_account(body, str(source["username"]))
    denial = foreign_action_denied(
        code, body, final_url, str(source["target"]), str(source["container"]),
        str(foreign["container"]), source_identity,
    )
    time.sleep(2)
    source_socket = "reachable" if stable_owner_ping(source["record"]) else "unreachable"
    foreign_socket = "reachable" if stable_owner_ping(foreign) else "unreachable"
    evidence = (
        f"http_{code};same_path_{'yes' if same_target(final_url, str(source['target'])) else 'no'};"
        f"identity_{'yes' if source_identity else 'no'};"
        f"denial_{'yes' if FAILURE_MESSAGE in body else 'no'};"
        f"podman_section_{'yes' if LIFECYCLE.PODMAN_SECTION.search(body) is not None else 'no'};"
        f"post_{LIFECYCLE.page_diagnostic(body)};"
        f"source_socket_{source_socket};foreign_socket_{foreign_socket};"
        f"success_{'yes' if LIFECYCLE.ACTION_SUCCESS in body else 'no'};"
        f"foreign_echo_{'yes' if str(foreign['container']) in body else 'no'}"
    )
    unchanged = (
        source_socket == "reachable"
        and foreign_socket == "reachable"
    )
    return denial and unchanged, evidence


def run(account_a: str, account_b: str, confirmed: bool) -> int:
    if not confirmed:
        print("Pass --confirm-cross-account-probe to submit foreign-container stop attempts.")
        return 2
    if os.geteuid() != 0 or not os.path.isfile(LIFECYCLE.WHMAPI1):
        print("Run this check as root on a cPanel host.")
        return 2
    if account_a == account_b:
        print("The two cPanel accounts must be distinct.")
        return 2

    records: list[dict[str, object]] = []
    stage = "container-discovery"
    action_sent = False
    failure: Exception | None = None
    evidence = ""
    try:
        records = [
            discover_owned_container(account_a),
            discover_owned_container(account_b),
        ]
        stage = "preflight"
        if not all(owner_ping(record) for record in records):
            raise RuntimeError("owner-container-not-reachable")
        stage = "account-a-sso"
        source_a = first_action_session(records[0])
        stage = "foreign-stop-a-to-b"
        action_sent = True
        passed, evidence = probe(source_a, records[1])
        if not passed:
            raise RuntimeError("foreign-action-not-safely-denied")
        del source_a

        stage = "account-b-sso"
        source_b = first_action_session(records[1])
        stage = "foreign-stop-b-to-a"
        action_sent = True
        passed, evidence = probe(source_b, records[0])
        if not passed:
            raise RuntimeError("foreign-action-not-safely-denied")
    except Exception as error:
        failure = error

    if failure is not None:
        if action_sent and records:
            restored = restore_reachable(records)
            suffix = (
                " Both owner-context PINGs were restored."
                if restored else " Owner-context recovery could not verify both PINGs."
            )
        else:
            suffix = " No lifecycle request was sent."
        print(
            f"Live cPanel Podman cross-account smoke failed at {stage} "
            f"({type(failure).__name__}); identifiers and page data were suppressed. "
            f"{evidence}" + suffix
        )
        return 1
    print(
        "Live cPanel Podman isolation passed: both foreign stop attempts were denied "
        "and both owner-context PINGs remained reachable."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account-a", required=True, help="first disposable cPanel account")
    parser.add_argument("--account-b", required=True, help="second disposable cPanel account")
    parser.add_argument(
        "--confirm-cross-account-probe", action="store_true",
        help="allow two foreign-container stop attempts",
    )
    args = parser.parse_args()
    try:
        return run(args.account_a, args.account_b, args.confirm_cross_account_probe)
    except ValueError:
        print("Provide valid, distinct cPanel account names.")
        return 2


if __name__ == "__main__":
    sys.exit(main())
