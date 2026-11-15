# Operations guide

This guide describes the intended operating behavior and identifies which controls are implemented in the current development build.

## Monitoring

Track service state, allocated and used memory, memory peak, connected clients, uptime, command throughput, cache hit ratio, evictions and last sample time. A failed sample should display a stale marker with the last known value. Avoid reading large key sets during routine monitoring.

## Backups and restore

- The cPanel page can create, list, and download an explicit RDB snapshot for the signed-in account. It does not enable Redis persistence or schedule jobs. The Redis-compatible service remains online during transfer; snapshot generation can add CPU and disk I/O load.
- ORM keeps the three newest successful snapshots per account. It removes the oldest only after a replacement has been generated and validated. A failed transfer leaves prior snapshots in place.
- Snapshots live beneath `/var/lib/orm-instances/.orm-backups/<account>`; the shared directory is root-controlled and each account directory and file is non-writable by that account. Only the matching cPanel account can read its snapshots. The broker validates ownership, type, link count, permissions and size before listing or serving a download.
- Backups are capped at 128 MiB and each transfer has a 60-second deadline. Large caches can exceed these limits; the UI reports an unavailable or failed operation without exposing command output.
- ORM has no restore UI or restore operation yet. Before implementing restore, create a safety snapshot, verify the resulting service state, and explain interruption and write-loss risks before confirmation. WHM fleet backups and per-account fleet results are also not implemented.
- Uninstall refuses while instance data remains, including backups. To uninstall or reinstall, first copy any required snapshots out of band, then remove the ORM data using the documented administrative procedure. Uninstall intentionally preserves account data.

## Recovery

Scan first. Show affected account names and the planned repair. Repair only selected/affected accounts; never reset all user session directories as a broad workaround. Rebuild configuration from trusted metadata, fix permissions minimally, and append an audit event with the outcome.

## Capacity

Package and reseller limits should gate new provisioning and configuration increases. Report current over-limit accounts without silently suspending them. Include system-level memory reserve and Redis overhead when calculating safe capacity.

## Incident diagnostics

Export version, backend, service state, bounded configuration, sample health and redacted logs. Exclude passwords, keys, application payloads, license secrets, and unrelated account files. Let the operator preview the bundle contents before download.
