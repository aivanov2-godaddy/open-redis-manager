# Managed-v1 upgrade validation record — 2026-11-20

## Test identity

- ORM change under test: PR #113, merge commit `7f340d7`.
- Host purpose: owner-designated cPanel test system.
- OS, cPanel release, architecture, and PHP runtimes: not captured in this operation record.
- Starting package: managed-v1 installation matching the exact pinned 28-file baseline.
- Redis/Valkey services: inventory was recorded before and after; this operation did not change their lifecycle.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Exact managed-v1 baseline preflight | PASS | The installed package matched the pinned 28-file baseline before upgrade. |
| Managed-v1 ORM package upgrade | PASS | The upgrade completed and the resulting install manifest validated. |
| WHM registration | PASS | Existing registration remained present after upgrade. |
| Broker service and socket | PASS | The broker remained enabled and active; its socket was ready after upgrade. |
| Account-scoped instance roots and data inventory | PASS | Before/after inventory was unchanged. |
| cPanel-managed EA Podman inventory | PASS | Before/after inventory was unchanged. |
| Failure rollback and interruption | NOT RUN on host | These paths are covered by isolated Linux packaging fixtures, including PR #114; live interruption recovery remains unvalidated. |
| Other upgrade baselines, fresh install, lifecycle, restore, Redis-to-Valkey migration, and uninstall | NOT RUN | Outside this managed-v1 upgrade run. |

## Result

- Overall result: the exact managed-v1 package upgraded successfully on one owner-designated cPanel test system.
- Evidence: [PR #113](https://github.com/aivanov2-godaddy/open-redis-manager/pull/113) records the live result; [PR #114](https://github.com/aivanov2-godaddy/open-redis-manager/pull/114) adds isolated interruption and rollback coverage.
- Known limitations: the test does not establish a supported OS/cPanel/PHP matrix, Redis/Valkey operational support, or full release readiness.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits the hostname, IP address, domain, account names, credentials, session URLs, private keys, and raw operational logs.
