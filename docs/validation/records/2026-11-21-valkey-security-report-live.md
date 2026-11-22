# Live ORM-managed Valkey security report — 2026-11-21

## Test identity

- Repository source: merged `main` commit `86bf34cc8b4374fd8dbcb5e683cceac490552b9d` before this evidence-only harness update.
- cPanel & WHM: `138.0 (build 27)`, RELEASE tier, AlmaLinux 10.3.
- Backend package: EasyApache `ea-valkey72`, version `7.2.15`.
- Test environment: owner-designated disposable cPanel system; host, account, and domain identifiers are omitted.
- The installed broker, WHM page, and report classes were checked against their repository SHA-256 values before the run. The live harnesses were copied from the repository and removed after validation.
- Live harness SHA-256: `tests/whm-live-security-report-engine.php` `5d797ca96996d829c2689ac32f6a6655c6ea1c265b330d3817f1ea4eb042a972`; `tests/whm-live-security-report-form.php` `7e5b8ae506bcec33a2bc9f69d4470f30948eb482a55448934667d545a143a195`.

## Live results

| Scenario | Result | Evidence |
|---|---|---|
| Initial state | PASS | No ORM-managed instances or backend selector existed before the test; the selected test account reported `not_configured`. |
| Temporary direct Valkey instance | PASS | ORM provisioned one account-scoped Valkey 7.2.15 instance. The first immediate metrics request landed during startup and returned unavailable; after a five-second readiness wait, two retained metrics samples succeeded. |
| Report engine | PASS | The live WHM report engine verified one Valkey backend, a valid bounded counter window, and generated the operation-rate, eviction-rate, and optional authentication findings in report-only mode. The full report inputs were available. |
| Authenticated WHM response | PASS | Root SSO rendered the report form and a report POST. The response contained the eviction, operation, and client authentication finding labels; a normalized `security.report` audit event was verified. |
| Redis keys, values, and secrets | NOT READ | Collection used bounded server metrics only. No keys, values, credentials, or client identities were read. |
| Cleanup | PASS | The temporary ORM service, instance configuration/data/metrics, metrics timer, and newly created Valkey selector were removed. The account returned to `not_configured`; fleet managed count returned to zero; both ORM units were inactive. Temporary harness files were removed. |
| EA Podman inventory | PASS | No Podman command or container mutation was part of the test. Final account-scoped inventory contained the existing Redis cache and no Valkey cache. |

The live report returned `partial=no`. The report operation consumed the one-minute report throttle and wrote its documented metadata-only audit event. No report threshold or Redis/Valkey cache data was changed.

The live engine was run with `ORM_LIVE_REQUIRE_VALKEY_EVIDENCE=1`; the authenticated form harness used the same flag with its explicit `--confirm-report-write` mode. Both modes emit pass/fail summaries only and do not retain report bodies or counter values.

## Scope and limits

This validates ORM-managed direct Valkey collection and report rendering on one cPanel host. cPanel EA Podman Valkey lifecycle has separate one-host evidence; at the time of this 2026-11-21 test, EA Podman counters were not yet verified in ORM security reports. The later Podman continuity-to-report validation is documented in the [2026-11-22 integration record](2026-11-22-ea-podman-security-report-live.md). This test does not establish a production support claim, browser visual review, another Valkey release, broader host coverage, cross-account authorization, or every report category. ORM support remains **NOT ESTABLISHED**.

The record omits hostnames, IP addresses, domains, account names, socket paths, counter values, report contents, credentials, SSO URLs/cookies, and raw operational logs.
