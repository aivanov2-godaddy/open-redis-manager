#!/usr/bin/env python3
"""Read-only two-account broker-isolation check for a disposable cPanel host.

Run as root with two distinct cPanel usernames and exactly one account that
already has an ORM-managed instance. Probes run through runuser so the broker
observes each account's real Unix-socket peer UID. No Redis keys or backup
contents are read, and no account, instance, service, or package is changed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

try:
    import pwd
except ImportError:  # Keep the helper's pure checks importable on Windows.
    pwd = None

USERNAME = re.compile(r"\A[a-zA-Z0-9_-]{1,16}\Z")
USERS_DIR = Path("/var/cpanel/users")
BROKER_SOCKET = Path("/run/orm/broker.sock")
BROKER_UNIT = "orm-broker.service"
TIMEOUT_SECONDS = 8
CONFIGURED_STATES = {"failed", "running", "starting", "stopped", "stopping"}
SAFE_STATUS_ERRORS = {"backend_unavailable", "instance_unavailable", "not_authorized", "not_configured", "operation_failed", "rate_limited"}

PYTHON_CLIENT = r'''
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5)
client.connect(sys.argv[1])
client.sendall(sys.argv[2].encode("utf-8"))
client.shutdown(socket.SHUT_WR)
response = bytearray()
while len(response) <= 262144:
    chunk = client.recv(4096)
    if not chunk:
        break
    response.extend(chunk)
    if b"\n" in chunk:
        break
if not response or len(response) > 262144 or b"\n" not in response:
    raise SystemExit(1)
sys.stdout.buffer.write(response)
'''


def validate_accounts(account_a: str, account_b: str) -> tuple[str, str]:
    if USERNAME.fullmatch(account_a) is None or USERNAME.fullmatch(account_b) is None:
        raise ValueError("invalid-account")
    if account_a == account_b:
        raise ValueError("accounts-must-differ")
    return account_a, account_b


def identity_matches(response: object, expected_user: str) -> bool:
    return (
        isinstance(response, dict)
        and response.get("success") is True
        and response.get("version") == 1
        and response.get("username") == expected_user
    )


def instance_state(response: object) -> str | None:
    if not isinstance(response, dict) or response.get("version") != 1:
        return None
    state = response.get("state")
    return state if state in CONFIGURED_STATES | {"not_configured"} else None


def reports_error(response: object, expected: str) -> bool:
    return (
        isinstance(response, dict)
        and response.get("success") is False
        and response.get("version") == 1
        and response.get("error") == expected
    )


def status_failure_reason(response: object) -> str:
    error = response.get("error") if isinstance(response, dict) else None
    if isinstance(error, str) and error in SAFE_STATUS_ERRORS:
        return error
    return "unexpected-response"


def _require_root() -> None:
    if not hasattr(os, "geteuid") or os.geteuid() != 0:
        raise RuntimeError("root-required")


def _check_prerequisites(account_a: str, account_b: str) -> tuple[str, str]:
    if pwd is None:
        raise RuntimeError("required-command-unavailable")
    runuser = shutil.which("runuser")
    python = shutil.which("python3")
    if runuser is None or python is None:
        raise RuntimeError("required-command-unavailable")

    active = subprocess.run(
        ["systemctl", "is-active", "--quiet", BROKER_UNIT],
        check=False,
        capture_output=True,
        timeout=TIMEOUT_SECONDS,
    )
    if active.returncode != 0:
        raise RuntimeError("broker-inactive")

    try:
        socket_info = BROKER_SOCKET.lstat()
    except OSError as error:
        raise RuntimeError("broker-socket-unavailable") from error
    if not stat.S_ISSOCK(socket_info.st_mode) or socket_info.st_uid != 0:
        raise RuntimeError("broker-socket-unsafe")

    users: list[object] = []
    for username in (account_a, account_b):
        metadata = USERS_DIR / username
        try:
            metadata_info = metadata.lstat()
            account = pwd.getpwnam(username)
        except (OSError, KeyError) as error:
            raise RuntimeError("cPanel-account-unavailable") from error
        if not stat.S_ISREG(metadata_info.st_mode) or metadata_info.st_uid != 0:
            raise RuntimeError("cPanel-account-metadata-unsafe")
        if account.pw_uid <= 0:
            raise RuntimeError("unsafe-account-uid")
        users.append(account)
    if users[0].pw_uid == users[1].pw_uid:
        raise RuntimeError("account-uids-must-differ")
    return runuser, python


def _frame(operation: str, target: str | None = None) -> str:
    request: dict[str, object] = {"operation": operation, "version": 1}
    if target is not None:
        request["username"] = target
    return json.dumps(request, sort_keys=True, separators=(",", ":")) + "\n"


def _probe(runuser: str, python: str, username: str, frame: str) -> object:
    for attempt in range(3):
        result = subprocess.run(
            [runuser, "-u", username, "--", python, "-c", PYTHON_CLIENT, str(BROKER_SOCKET), frame],
            check=False,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            raise RuntimeError("broker-probe-failed")
        try:
            response = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError("broker-response-invalid") from error
        if not isinstance(response, dict):
            raise RuntimeError("broker-response-invalid")
        if response.get("error") != "rate_limited" or attempt == 2:
            return response
        time.sleep(1.1)
    raise RuntimeError("broker-response-invalid")


def run(account_a: str, account_b: str, fixture_owner: str) -> int:
    _require_root()
    account_a, account_b = validate_accounts(account_a, account_b)
    if fixture_owner not in {"a", "b"}:
        raise ValueError("invalid-fixture-owner")
    runuser, python = _check_prerequisites(account_a, account_b)
    accounts = {"a": account_a, "b": account_b}
    owner = accounts[fixture_owner]
    other = accounts["b" if fixture_owner == "a" else "a"]

    for label, username in accounts.items():
        identity = _probe(runuser, python, username, _frame("identity"))
        if not identity_matches(identity, username):
            raise RuntimeError(f"identity-check-failed-{label}")

        status = _probe(runuser, python, username, _frame("instance.status"))
        if instance_state(status) is None:
            raise RuntimeError(f"status-check-failed-{label}-{status_failure_reason(status)}")

        backups = _probe(runuser, python, username, _frame("backup.list"))
        backups_valid = (
            isinstance(backups, dict)
            and backups.get("version") == 1
            and (
                backups.get("success") is True and isinstance(backups.get("backups"), list)
                or reports_error(backups, "not_configured")
            )
        )
        if not backups_valid:
            raise RuntimeError(f"backup-list-check-failed-{label}")

    owner_state = instance_state(_probe(runuser, python, owner, _frame("instance.status")))
    other_state = instance_state(_probe(runuser, python, other, _frame("instance.status")))
    if owner_state not in CONFIGURED_STATES or other_state != "not_configured":
        raise RuntimeError("cross-account-resource-boundary-not-proven")

    for username, target, label in (
        (account_a, account_b, "a-to-b"),
        (account_b, account_a, "b-to-a"),
    ):
        for operation in ("instance.status", "backup.list"):
            response = _probe(runuser, python, username, _frame(operation, target))
            if not reports_error(response, "invalid_request"):
                raise RuntimeError(f"target-injection-not-rejected-{label}")
        fleet = _probe(runuser, python, username, _frame("provider.resellers"))
        if not reports_error(fleet, "not_authorized"):
            raise RuntimeError(f"root-only-operation-not-denied-{label}")

    print("Two-account broker identity, resource-boundary, and target-denial checks passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account-a", required=True, help="first safe cPanel username")
    parser.add_argument("--account-b", required=True, help="second safe cPanel username")
    parser.add_argument(
        "--fixture-owner",
        required=True,
        choices=("a", "b"),
        help="which account already has the disposable ORM-managed instance",
    )
    args = parser.parse_args()
    try:
        return run(args.account_a, args.account_b, args.fixture_owner)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        reason = str(error)
        if reason.startswith(("status-check-failed-a-", "status-check-failed-b-")):
            print(f"Live cPanel isolation smoke failed ({reason}).")
            return 1
        if reason not in {
            "root-required", "invalid-account", "accounts-must-differ", "invalid-fixture-owner",
            "required-command-unavailable", "broker-inactive", "broker-socket-unavailable",
            "broker-socket-unsafe", "cPanel-account-unavailable", "cPanel-account-metadata-unsafe",
            "unsafe-account-uid", "account-uids-must-differ", "broker-probe-failed",
            "broker-response-invalid", "cross-account-resource-boundary-not-proven",
            "identity-check-failed-a", "identity-check-failed-b", "status-check-failed-a",
            "status-check-failed-b", "backup-list-check-failed-a", "backup-list-check-failed-b",
            "target-injection-not-rejected-a-to-b", "target-injection-not-rejected-b-to-a",
            "root-only-operation-not-denied-a-to-b", "root-only-operation-not-denied-b-to-a",
        }:
            reason = "unexpected-error"
        print(f"Live cPanel isolation smoke failed ({reason}).")
        return 1


if __name__ == "__main__":
    sys.exit(main())
