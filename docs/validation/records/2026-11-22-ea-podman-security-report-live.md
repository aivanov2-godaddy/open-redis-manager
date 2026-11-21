# Live EA Podman security-report integration — 2026-11-22

## Scope and source identity

- The installed Podman collector, broker fleet-summary path, WHM report engine, and WHM entry point matched the checked-out ORM source before execution.
- Repository revision under validation: `ffab17c` (`main`).
- Runtime: cPanel & WHM 138.0 build 27 with EasyApache PHP 8.5.12 on an owner-designated test system. Server and account identifiers are omitted.
- The sample was deliberately scoped to one existing account-owned EA Podman Redis process. No temporary container was installed.
- The live harness, report-engine check, and authenticated-form check were SHA-256 verified before execution (`f6167052d1b89dfd60292968eb4c71d9e152da47f2e2a3368249ba262b408eec`, `d70d02d6a244896f4ed2e7d1033126bc54ff1a5c26716de82545c76e4fa3442a`, and `a9535cf25c797021166c4ffc4d0d5d4deaa766652d76e091d93250202292533d`). Their temporary root-owned copies were removed after validation.

## Live results

| Check | Result | Evidence |
|---|---|---|
| Initial sampler read | PASS | A complete one-account inventory produced the expected first-sample state; no rate was inferred from cumulative counters. |
| Continuity window | PASS | A second sample 65 seconds later matched the same process set and monotonic counters; one process contributed to the measured window. |
| Broker and report engine | PASS | The local broker returned the measured aggregate window; the report engine generated report-only eviction, operation-rate, and optional authentication findings. |
| Authenticated WHM form | PASS | cPanel-created WHM SSO submitted a report request; all three Podman finding labels rendered and the normalized `security.report` audit event was verified. |
| Policy and services | NOT CHANGED | No thresholds, backend selection, Redis/Valkey service, or container lifecycle action was changed. The report-only generation throttle was consumed by the test. |
| Cleanup and timer | PASS | Temporary sampler state and account-scope files were removed. The sampler timer remained disabled and inactive. The pre-existing EA Podman inventory remained at one Redis container and zero Valkey containers. |
| Redis data | NOT READ | The sampler used fixed INFO counters; no keys, values, or credentials were requested or retained. |

## Limits and sanitization

This validates the Podman continuity-to-WHM-report path on one test account and one cPanel host. It does not establish support for a broader host, package, or version matrix; validate load behavior; or replace browser visual review. A one-account complete scan is not evidence of complete host-wide coverage. The record omits hostnames, IP addresses, domains, account names, socket paths, container IDs, counter values, credentials, SSO material, and raw operational output.
