# Live cPanel two-account broker isolation — 2026-11-20

## Scope

The owner-designated disposable cPanel system was used to verify that the broker binds requests to the caller's actual Unix UID and does not allow one cPanel account to inspect another account's managed instance or backups.

## Procedure

- Created a temporary cPanel account and a disposable ORM-managed Valkey instance for the fixture owner.
- Staged the current broker source and tests, ran the complete broker Perl suite as an unprivileged user, and installed the exact staged `InstanceManager.pm` into the test system before restarting `orm-broker.service`.
- Ran `tests/cpanel-live-isolation-smoke.py` as root with two distinct cPanel accounts. Every probe ran under the real account UID using `runuser` and the broker's Unix socket.
- The harness checked both account identities, per-account status and backup-list shapes, the configured owner's instance state, the other account's `not_configured` state, rejected cross-account username targets for status and backup listing, and denied the root-only reseller summary to both non-root accounts.
- The harness read backup metadata only; it did not read Redis keys or backup contents.

## Results

- Broker Perl suite: **PASS**, 368 tests, run as `nobody` on Linux. This exercises systemd `activating` and `deactivating` responses as `starting` and `stopping` instead of `instance_unavailable`.
- Live account creation, broker identity, and fixture provisioning: **PASS**.
- Live instance status while systemd reported `activating`: **PASS**, reported `starting`.
- Two-account identity, resource-boundary, and target-denial checks: **PASS**.
- Cleanup of the temporary account, instance, and temporary backend policy: **PASS**.

The test system's broker module was source-matched to the staged repository file. The instance and temporary policy were removed by the harness; the test service retains the validated source change. A root-only copy of the prior module was kept outside the repository for rollback.

This is one disposable-host result. It does not establish a supported OS/cPanel matrix or production readiness. No host address, hostname, account name, domain, credential, session URL, or raw server transcript is included in this record.
