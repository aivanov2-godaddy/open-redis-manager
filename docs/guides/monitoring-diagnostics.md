# Monitoring, health and diagnostics

## Metrics

The installed cPanel page requests one bounded Redis-compatible INFO sample for memory/current peak, connected clients, uptime, operations per second, and keyspace hits/misses. Values are normalized to numeric fields. The broker atomically retains only the latest sample in a root-owned `0600` file beside the account manifest; cPanel accounts cannot read or modify it. When the service stops or a live probe fails, the page shows that sample as stale with its UTC capture time. Snapshots expire after 30 days and are removed on the next metrics request; no time series is stored. The response identifies whether that specific live sample was saved. If persistence fails, the current values remain available and the page says they were not saved for fallback; a missing, invalid, or expired snapshot leaves the existing unavailable/stopped response in place. The public reference also names latency and trend history; those remain unimplemented. Never equate a high health score with an uptime guarantee.

## Health score

Use understandable sub-signals: service availability, memory pressure, connection saturation, cache hit ratio, uptime and authentication posture. A score should link to underlying observations and recommended actions so it does not hide the reason for a warning.

## Application preflight

Check service initialization, running status, authentication and PHP client availability. Discovery may inspect safe marker files for common frameworks, but should not read source secrets or edit application files.

## Exportable diagnostics

Provide a preview that lists included fields. Redact credentials and tokens; exclude application payload, session identifiers, private keys and unrelated files. Record export events without recording the bundle's sensitive contents.
