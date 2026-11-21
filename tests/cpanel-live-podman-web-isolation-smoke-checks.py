#!/usr/bin/env python3
"""Offline assertions for the two-account cPanel Podman isolation smoke."""

from __future__ import annotations

import importlib.util
import json
import stat
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "cpanel_live_podman_web_isolation_smoke",
    Path(__file__).with_name("cpanel-live-podman-web-isolation-smoke.py"),
)
assert SPEC is not None and SPEC.loader is not None
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)

TARGET = "https://cpanel.example/cpsess1234567890/frontend/jupiter/orm/index.live.php"
FOREIGN = "ea-redis62.accountb.01"
SOURCE = "ea-redis62.accounta.01"
DENIED = "The container action could not be completed."
DENIED_PAGE = (
    "<p>Verified cPanel account: <code>accounta</code></p>"
    '<section aria-labelledby="orm-podman-title">'
    f'<input name="orm_podman_container" value="{SOURCE}">'
    + DENIED
    + "</section>"
)
assertions = 0


def check(condition: bool, message: str) -> None:
    global assertions
    assertions += 1
    if not condition:
        raise AssertionError(message)


check(
    SMOKE.foreign_action_denied(
        200, DENIED_PAGE, TARGET, TARGET, SOURCE, FOREIGN, True
    ),
    "accept a generic denial from the verified owner's Podman section",
)
check(
    not SMOKE.foreign_action_denied(
        200, "The cPanel container action completed.", TARGET, TARGET,
        SOURCE, FOREIGN, True,
    ),
    "reject a successful foreign action",
)
check(
    not SMOKE.foreign_action_denied(
        302, DENIED_PAGE, TARGET, TARGET, SOURCE, FOREIGN, True
    ),
    "treat a redirect response as inconclusive instead of denial",
)
check(
    not SMOKE.foreign_action_denied(
        200, DENIED, TARGET, TARGET, SOURCE, FOREIGN, True
    ),
    "reject a denial marker outside the authenticated Podman section",
)
check(
    not SMOKE.foreign_action_denied(
        200, DENIED_PAGE, TARGET, TARGET, SOURCE, FOREIGN, False
    ),
    "reject a denial response without verified source identity",
)
check(
    not SMOKE.foreign_action_denied(
        500, DENIED_PAGE, TARGET, TARGET, SOURCE, FOREIGN, True
    ),
    "reject a denial marker on a failed HTTP status",
)
check(
    not SMOKE.foreign_action_denied(
        200, DENIED_PAGE,
        TARGET.replace("/cpsess1234567890/", "/cpsess9999999999/"),
        TARGET, SOURCE, FOREIGN, True,
    ),
    "reject a response from a different cPanel session",
)
check(
    not SMOKE.foreign_action_denied(
        200, DENIED_PAGE + FOREIGN, TARGET, TARGET, SOURCE, FOREIGN, True
    ),
    "reject a response that exposes the foreign container identifier",
)
check(
    not SMOKE.foreign_action_denied(
        200, DENIED_PAGE, "https://outside.example/page", TARGET,
        SOURCE, FOREIGN, True,
    ),
    "reject a response from another origin",
)
check(
    not SMOKE.foreign_action_denied(
        200,
        DENIED_PAGE.replace(SOURCE, "ea-redis62.other.01"),
        TARGET, TARGET, SOURCE, FOREIGN, True,
    ),
    "reject a response not bound to the source account's own cache",
)
check(
    SMOKE.same_target(TARGET, TARGET + "?notice=denied"),
    "allow query-only changes on the same page path",
)
check(
    not SMOKE.same_target(
        TARGET,
        "https://outside.example/cpsess1234567890/frontend/jupiter/orm/index.live.php",
    ),
    "reject another origin",
)
check(
    SMOKE.owned_container_id(
        {
            "ea-redis62.accountb.01": {
                "container_name": "ea-redis62.accountb.01",
                "user": "accountb",
            }
        },
        "accountb",
    ) == FOREIGN,
    "accept the single container explicitly owned by the selected account",
)
check(
    SMOKE.owned_container_id(
        {
            "ea-valkey73.accounta.02": {
                "container_name": "ea-valkey73.accounta.02",
                "user": "accounta",
            }
        },
        "accounta",
    ) == "ea-valkey73.accounta.02",
    "accept an account-owned Valkey container",
)
for invalid_payload, account in (
    (
        {"ea-redis62.accountb.01": {
            "container_name": "ea-redis62.accountb.01", "user": "accounta",
        }},
        "accountb",
    ),
    (
        {"ea-redis62.accountb.01": {
            "container_name": "ea-redis62.other.01", "user": "accountb",
        }},
        "accountb",
    ),
    (
        {
            "ea-redis62.accountb.01": {
                "container_name": "ea-redis62.accountb.01", "user": "accountb",
            },
            "ea-valkey73.accountb.02": {
                "container_name": "ea-valkey73.accountb.02", "user": "accountb",
            },
        },
        "accountb",
    ),
):
    try:
        SMOKE.owned_container_id(invalid_payload, account)
    except RuntimeError:
        check(True, "reject foreign, mismatched, or ambiguous container ownership")
    else:
        check(False, "reject foreign, mismatched, or ambiguous container ownership")
check(
    SMOKE.container_socket_name("ea-redis62.accounta.01") == "redis.sock",
    "map Redis to its fixed socket basename",
)
check(
    SMOKE.container_socket_name("ea-valkey73.accountb.02") == "valkey.sock",
    "map Valkey to its fixed socket basename",
)
check(
    SMOKE.socket_is_owned_and_private(stat.S_IFSOCK | 0o660, 1000, 1000),
    "allow an account-owned socket with no world permissions",
)
check(
    not SMOKE.socket_is_owned_and_private(stat.S_IFSOCK | 0o666, 1000, 1000),
    "reject a world-accessible socket",
)
check(
    not SMOKE.socket_is_owned_and_private(stat.S_IFSOCK | 0o600, 1001, 1000),
    "reject a socket owned by another account",
)
try:
    SMOKE.container_socket_name("ea-mysql.accountb.01")
except ValueError:
    check(True, "reject unsupported container types")
else:
    check(False, "reject unsupported container types")
check(
    SMOKE.parse_ea_podman_output(
        'cPanel warning\n{"ea-redis62.accountb.01":{"user":"accountb"}}\n'
    )["ea-redis62.accountb.01"]["user"] == "accountb",
    "parse the account's JSON after a cPanel warning",
)
try:
    SMOKE.parse_ea_podman_output(
        '{"ea-redis62.accountb.01":{"user":"accountb"}} trailing-data'
    )
except RuntimeError:
    check(True, "reject ambiguous command output")
else:
    check(False, "reject ambiguous command output")
check(
    SMOKE.LIFECYCLE.container_belongs_to_user(
        "ea-redis62.accounta.01", "accounta"
    ),
    "recognize a container owned by its named account",
)
check(
    not SMOKE.LIFECYCLE.container_belongs_to_user(FOREIGN, "accounta"),
    "reject a foreign account's container",
)
try:
    compile(SMOKE.OWNER_PING_PROGRAM, "<owner-ping>", "exec")
except SyntaxError:
    check(False, "keep the owner-context Redis PING program syntactically valid")
else:
    check(True, "keep the owner-context Redis PING program syntactically valid")

print(f"cPanel live Podman web isolation assertions passed: {assertions}")
