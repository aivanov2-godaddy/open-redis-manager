#!/usr/bin/env python3
"""Unit checks for the sanitized live cPanel isolation smoke harness."""

from __future__ import annotations

import importlib.util
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("cpanel-live-isolation-smoke.py")
SPEC = importlib.util.spec_from_file_location("cpanel_live_isolation_smoke", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("unable to load the live cPanel isolation smoke module")
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)

checks = 0


def check(condition: bool, description: str) -> None:
    global checks
    checks += 1
    if not condition:
        raise SystemExit(f"FAIL: {description}")


check(SMOKE.validate_accounts("accounta", "accountb") == ("accounta", "accountb"),
      "accept two distinct safe usernames")
for accounts, expected in ((('bad/name', 'accountb'), "invalid-account"),
                           (('accounta', 'accounta'), "accounts-must-differ")):
    try:
        SMOKE.validate_accounts(*accounts)
    except ValueError as error:
        check(str(error) == expected, f"reject account input: {expected}")
    else:
        check(False, f"reject account input: {expected}")

check(SMOKE.identity_matches({"success": True, "username": "accounta", "version": 1}, "accounta"),
      "accept broker identity matching the socket peer account")
check(not SMOKE.identity_matches({"success": True, "username": "accountb", "version": 1}, "accounta"),
      "reject broker identity for another account")
check(SMOKE.instance_state({"state": "running", "version": 1}) == "running",
      "recognize a configured instance state")
check(SMOKE.instance_state({"state": "not_configured", "version": 1}) == "not_configured",
      "recognize an account without an ORM instance")
check(SMOKE.instance_state({"state": "invalid", "version": 1}) is None,
      "reject unknown instance states")
check(SMOKE.reports_error({"error": "invalid_request", "success": False, "version": 1}, "invalid_request"),
      "recognize the expected protocol denial")
check(SMOKE.status_failure_reason({"error": "instance_unavailable"}) == "instance_unavailable",
      "preserve only a bounded broker status error code for diagnostics")
check(SMOKE.status_failure_reason({"error": "private-detail"}) == "unexpected-response",
      "hide unrecognized broker diagnostics")
check(not SMOKE.reports_error({"error": "operation_failed", "success": False, "version": 1}, "invalid_request"),
      "do not treat an unrelated broker error as a denial pass")

with (
    patch.object(SMOKE.subprocess, "run", side_effect=[
        SimpleNamespace(returncode=0, stdout='{"error":"rate_limited","success":false,"version":1}'),
        SimpleNamespace(returncode=0, stdout='{"success":true,"username":"accounta","version":1}'),
    ]) as run_command,
    patch.object(SMOKE.time, "sleep") as wait,
):
    identity = SMOKE._probe("runuser", "python3", "accounta", SMOKE._frame("identity"))
check(identity["username"] == "accounta" and run_command.call_count == 2,
      "retry one broker request after a rate-limit response")
check(wait.call_args.args == (1.1,), "wait for a fresh rate window before retrying")


def fake_probe(_runuser: str, _python: str, username: str, frame: str) -> dict[str, object]:
    request = json.loads(frame)
    operation = request["operation"]
    target = request.get("username")
    if operation == "identity":
        return {"success": True, "username": username, "version": 1}
    if operation == "instance.status" and target is None:
        state = "running" if username == "accounta" else "not_configured"
        return {"success": True, "state": state, "version": 1}
    if operation == "backup.list" and target is None:
        return {"backups": [], "success": True, "version": 1}
    if operation in {"instance.status", "backup.list"} and target is not None:
        return {"error": "invalid_request", "success": False, "version": 1}
    if operation == "provider.resellers":
        return {"error": "not_authorized", "success": False, "version": 1}
    return {"error": "invalid_request", "success": False, "version": 1}


def missing_backup_probe(_runuser: str, _python: str, username: str, frame: str) -> dict[str, object]:
    operation = json.loads(frame)["operation"]
    if operation == "identity":
        return {"success": True, "username": username, "version": 1}
    if operation == "instance.status":
        return {"success": True, "state": "not_configured", "version": 1}
    return {"success": True, "version": 1}


with (
    patch.object(SMOKE, "_require_root"),
    patch.object(SMOKE, "_check_prerequisites", return_value=("runuser", "python3")),
    patch.object(SMOKE, "_probe", side_effect=fake_probe) as probe,
    redirect_stdout(io.StringIO()),
):
    result = SMOKE.run("accounta", "accountb", "a")
check(result == 0, "pass the full two-account fixture and denial sequence")
check(probe.call_count == 14, "probe both identities, resource views, injected targets, and root-only denial")

with (
    patch.object(SMOKE, "_require_root"),
    patch.object(SMOKE, "_check_prerequisites", return_value=("runuser", "python3")),
    patch.object(SMOKE, "_probe", side_effect=missing_backup_probe),
    redirect_stdout(io.StringIO()),
):
    try:
        SMOKE.run("accounta", "accountb", "a")
    except RuntimeError as error:
        check(str(error) == "backup-list-check-failed-a", "stop if the broker cannot provide a scoped backup-list response")
    else:
        check(False, "reject probes that do not return the expected response shapes")

print(f"Live cPanel isolation smoke assertions passed: {checks} checks.")
