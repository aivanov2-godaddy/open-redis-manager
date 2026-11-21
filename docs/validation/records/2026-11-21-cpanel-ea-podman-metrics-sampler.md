# cPanel EA Podman metrics sampler validation — 2026-11-21

## Scope

Validated the source-matched `PodmanMetricsCollector` from the EA Podman metrics change on a disposable cPanel host. The one-shot root collector was restricted to one test account. A temporary Valkey container was installed in that account's context to exercise Redis and Valkey together, then removed after the check.

Host, account, network, and package inventory identifiers are intentionally omitted.

## Results

| Check | Result | Evidence |
|---|---|---|
| Collector and test entry point syntax | PASS | Perl compiled the one-shot entry point and loaded the collector module. |
| Existing Redis socket | PASS | The socket was discovered and the peer-credential check matched its account owner. |
| Temporary Valkey socket | PASS | The account-owned socket was discovered and passed the same peer-credential check. |
| Anonymous aggregate snapshot | PASS | `discovered=2`, `sampled=2`, `reachable=2`, `partial=no`; the snapshot passed schema validation. |
| Recurring sampler | NOT ENABLED | The systemd timer remained disabled; validation used a one-shot invocation. |
| Temporary data cleanup | PASS | The temporary Valkey container, its fresh-install backup directory, and the root-only validation directory were removed. The pre-existing Redis container was left untouched. |

The collector reads only its allowlisted INFO counters into the aggregate snapshot. It does not query Redis/Valkey keys or values. Temporary validation files and the anonymous snapshot were deleted; no host, account, credentials, counters, or service configuration were added to the repository.

This is runtime evidence for one disposable cPanel host and the tested Redis/Valkey packages. It does not establish the supported-host matrix or authorize enabling the scheduled sampler by default.
