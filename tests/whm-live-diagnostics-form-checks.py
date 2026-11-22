#!/usr/bin/env python3
"""Offline assertions for the opt-in root WHM diagnostics smoke harness."""

from pathlib import Path

script = Path(__file__).with_name("whm-live-diagnostics-form.php").read_text(encoding="utf-8")
checks = {
    "requires an explicit read-only confirmation": "--confirm-live-reads" in script,
    "validates the selected account identifier": "[a-zA-Z0-9_-]{1,16}" in script,
    "requires root and the installed WHM runtime": "posix_geteuid() !== 0" in script
    and "service=whostmgrd" in script,
    "creates SSO cookies in a private temporary directory": "mkdir($temporaryDirectory, 0700)" in script
    and "chmod($cookieFile, 0600)" in script,
    "pins HTTPS to the local WHM listener": "CURLOPT_RESOLVE => [$host . ':2087:127.0.0.1']" in script,
    "keeps redirects inside the same SSO session": "outside the authenticated session" in script,
    "covers all eight fixed command classes": all(
        f"'{name}' =>" in script
        for name in ("ping", "info_server", "info_memory", "info_clients", "info_stats", "info_commandstats", "slowlog", "dbsize")
    ),
    "waits for the per-account diagnostic throttle window": "usleep(5_100_000)" in script,
    "checks class-specific successful audit records": "'diagnostics.' . $commandClass" in script
    and "_audit']" in script,
    "checks rapid-repeat throttling and its audit event": "'rate_limited'" in script
    and "'throttle' => false" in script,
    "submits an unsupported class to verify fail-closed rejection": "'command_class' => 'flushall'" in script
    and "unsupported_rejected" in script,
    "does not print response bodies or diagnostic values": all(
        forbidden not in script for forbidden in ("var_dump(", "print_r(", "fwrite(STDOUT, $body")
    ),
}
failed = [description for description, passed in checks.items() if not passed]
if failed:
    raise SystemExit("WHM live diagnostics smoke assertions failed: " + "; ".join(failed))
print(f"WHM live diagnostics smoke assertions passed: {len(checks)} checks.")
