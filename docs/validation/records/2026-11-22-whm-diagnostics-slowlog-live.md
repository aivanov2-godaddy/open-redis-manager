# Live WHM diagnostics and slow-log validation — 2026-11-22

## Scope and source identity

- Repository candidate: `adad37ca1ef729e4be8022315c843c26bb53dead` (`0.1.0-rc.14`), built from merged source `59ab076` plus the candidate version update.
- Installed candidate: `0.1.0-rc.14` on cPanel & WHM 138.0 (build 27).
- Environment: owner-authorized disposable cPanel test system; host, account, and domain identifiers are intentionally omitted.
- Signed preview: source and signature verification passed; the reviewed change set contained nine replacements and 57 unchanged files, with no conflicts. The first asynchronous apply attempt was safely refused because the broker was active. After confirming the existing managed instance was stopped, the official transactional updater applied the candidate under a guarded maintenance window and restored the broker to its prior active state.

## Live results

The source-matched root WHM diagnostics form was exercised through an authenticated cPanel SSO session. The harness returned pass for each fixed probe and its per-class audit event, the throttled repeat, and unsupported-class rejection.

| Scenario | Result | Evidence |
|---|---|---|
| Root WHM diagnostics form | PASS | Authenticated form rendered the fixed read-only controls. |
| PING | PASS | Bounded result and `diagnostics.ping` audit event. |
| INFO server | PASS | Bounded result and `diagnostics.info_server` audit event. |
| INFO memory | PASS | Bounded result and `diagnostics.info_memory` audit event. |
| INFO clients | PASS | Bounded result and `diagnostics.info_clients` audit event. |
| INFO stats | PASS | Bounded result and `diagnostics.info_stats` audit event. |
| INFO commandstats | PASS | Bounded result and `diagnostics.info_commandstats` audit event. |
| SLOWLOG | PASS | Bounded result and `diagnostics.slowlog` audit event. |
| DBSIZE | PASS | Bounded result and `diagnostics.dbsize` audit event. |
| Rapid repeat | PASS | Per-class repeat was rate-limited and audited. |
| Unsupported class | PASS | `flushall` was rejected before broker execution and no diagnostic result was rendered. |
| Installed module identity | PASS | Installed `InstanceManager.pm` SHA-256 matched the reviewed replacement digest. |
| Existing test instance | RESTORED | The pre-existing account-scoped instance was stopped after probes; status reported `stopped`. |
| Broker service | RESTORED | Broker returned to `active` and remained `enabled`. |
| Existing EA Podman container | PRESERVED | Post-test inventory count remained one. |
| Backend policy | UNCHANGED | No provider selection policy was configured or modified. |
| Test signing key and release staging | RESTORED | Temporary public key removed; the prior four staged files were restored and their hashes matched the saved pre-test values. The private test key remained local and was never committed or transferred to the test host. |

The live probe run used the candidate harness before the following repository-only correction: its final status sentence said “seven” although the harness executed eight fixed classes. The sentence and the smoke guide now say “eight”; no probe logic changed.

## Evidence limits and remaining work

This validates the eight fixed read-only diagnostics and transactional update on one disposable cPanel test system. It does not validate every WHM mutation, recovery from a forcibly interrupted update, other cPanel/OS/PHP combinations, or production support. **ORM support remains NOT ESTABLISHED.**

The update preview's initial asynchronous apply attempt correctly did not change installed files because the broker-active guard rejected that transaction. A guarded maintenance apply then succeeded. This exposed a WHM usability gap: the form allowed queueing work that the worker would later refuse. The UI should surface the maintenance requirement before queueing a change set that touches broker or systemd files.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, SSO URLs or cookies, Redis values, raw response bodies, and raw operational logs. The private test key was never committed or transferred to the test host; its temporary public half was removed from the host.
