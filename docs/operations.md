# Operations guide

This guide describes the intended operating behavior and identifies which controls are implemented in the current development build.

## Monitoring

Track service state, allocated and used memory, memory peak, connected clients, uptime, command throughput, cache hit ratio, evictions and last sample time. The installed cPanel page provides current values and hourly memory, client, and hit-ratio trends for 24 hours or 7 days. Collection runs hourly under the account identity while its instance is active; root-owned history is retained for up to 30 days and capped at 720 samples. A failed live sample displays the last known value with a stale marker. Avoid reading large key sets during routine monitoring.

## Backups and restore

- The cPanel page can create, list, download, and restore explicit RDB snapshots for the signed-in account. It does not enable Redis persistence or schedule jobs. The Redis-compatible service remains online during backup transfer; snapshot generation can add CPU and disk I/O load.
- ORM keeps two or three successful snapshots per account according to the enforced package policy (three in report-only mode). It removes older snapshots only after a replacement has been generated and validated. A failed transfer leaves prior snapshots in place.
- Snapshots live beneath `/var/lib/orm-instances/.orm-backups/<account>`; the shared directory is root-controlled and each account directory and file is non-writable by that account. Only the matching cPanel account can read its snapshots. The broker validates ownership, type, link count, permissions and size before listing or serving a download.
- Backups are capped at 128 MiB and each transfer has a 60-second deadline. Large caches can exceed these limits; the UI reports an unavailable or failed operation without exposing command output.
- Restore is available for a running account instance. The broker accepts only a retained snapshot ID from that account, copies and checks the RDB with the installed backend checker, creates a safety snapshot, stops the service, atomically replaces `dump.rdb`, and verifies that the service becomes active. If the restored snapshot fails to start, it reinstalls the safety snapshot and attempts to start the service. The page warns that restore briefly interrupts cache access and loses writes newer than the selected snapshot; it reports the safety snapshot ID. The operation is rate-limited and audited without credentials. If validation or rollback cannot be confirmed, the operation fails and reports the unresolved service state. Keep a separate copy of important cache data before relying on recovery. Restore requires the backend's `redis-check-rdb` or `valkey-check-rdb` executable.
- Root WHM administrators can list up to three snapshots for each displayed account, create a snapshot, and restore a selected snapshot one account at a time. WHM shows each request's account-specific result and safety snapshot ID, uses the same broker validation and rollback path as cPanel, and does not offer synchronous all-fleet batching. Fleet backup requests are rate-limited per account. Disposable-host validation is still required before production use.
- Uninstall refuses while instance data remains, including backups. To uninstall or reinstall, first copy any required snapshots out of band, then remove the ORM data using the documented administrative procedure. Uninstall intentionally preserves account data.

## Recovery

Scan first. Show affected account names and the planned repair. Repair only selected/affected accounts; never reset all user session directories as a broad workaround. Rebuild configuration from trusted metadata, fix permissions minimally, and append an audit event with the outcome.

## Capacity

Package and reseller limits should gate new provisioning and configuration increases. Report current over-limit accounts without silently suspending them. Include system-level memory reserve and Redis overhead when calculating safe capacity.

## Incident diagnostics

The installed cPanel page offers a preview and explicit download for a minimal JSON report containing schema/generation metadata, normalized instance state, allowlisted preset and bounded configuration, fixed connection-mode flags, the AUTH configured state (`true`, `false`, or `null` when unknown), and the latest numeric metric sample with stale/retention status. It includes no backend executable output, account name, hostname, socket path, logs, passwords, tokens, keys, values, application payloads, sessions, license data or unrelated files. The report is assembled in memory and not stored by ORM. See the [monitoring and diagnostics guide](guides/monitoring-diagnostics.md).
