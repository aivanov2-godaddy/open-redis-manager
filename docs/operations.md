# Operations guide

This guide describes intended operating behavior for the production plugin. The current screens are a prototype only.

## Monitoring

Track service state, allocated and used memory, memory peak, connected clients, uptime, command throughput, cache hit ratio, evictions and last sample time. A failed sample should display a stale marker with the last known value. Avoid reading large key sets during routine monitoring.

## Backups and restore

- Keep snapshots under the owning account's boundary and apply retention limits from provider policy.
- A backup should report whether it completed and its size/time; fleet runs should show per-account outcomes.
- Before restore, create a safety snapshot of the current data and verify ownership/permissions after writing.
- Document whether the operation pauses the service, loses writes, or affects clients before the user confirms it.

## Recovery

Scan first. Show affected account names and the planned repair. Repair only selected/affected accounts; never reset all user session directories as a broad workaround. Rebuild configuration from trusted metadata, fix permissions minimally, and append an audit event with the outcome.

## Capacity

Package and reseller limits should gate new provisioning and configuration increases. Report current over-limit accounts without silently suspending them. Include system-level memory reserve and Redis overhead when calculating safe capacity.

## Incident diagnostics

Export version, backend, service state, bounded configuration, sample health and redacted logs. Exclude passwords, keys, application payloads, license secrets, and unrelated account files. Let the operator preview the bundle contents before download.
