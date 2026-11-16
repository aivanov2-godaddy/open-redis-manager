# Monitoring, health and diagnostics

## Metrics

The installed cPanel page requests one bounded Redis-compatible INFO sample for memory/current peak, connected clients, uptime, operations per second, and keyspace hits/misses. Values are normalized to numeric fields. The broker atomically retains the latest sample in a root-owned `0600` file beside the account manifest; cPanel accounts cannot read or modify it. When the service stops or a live probe fails, the page shows that sample as stale with its UTC capture time. Latest samples expire after 30 days.

A separate per-account `orm-metrics-collect@<account>.timer` invokes the fixed collector hourly as the cPanel account, through the local Unix socket. It runs only while the account's ORM instance is active. Each successful sample updates that hour's bucket in a root-owned `0600` history file protected by a root-owned lock and atomic replacement. History is capped at 720 hourly records, 256 KiB and 30 days. The cPanel page offers 24-hour and 7-day charts for memory, connected clients and hit ratio. Values are numeric allowlist fields; history requests accept only those two fixed ranges and return at most 24 or 168 points. If the timer cannot be scheduled, the page reports that; it does not silently present an empty range as working collection. The reference also mentions latency, which is not currently sampled. Never equate a high health score with an uptime guarantee.

## Health score

Use understandable sub-signals: service availability, memory pressure, connection saturation, cache hit ratio, uptime and authentication posture. A score should link to underlying observations and recommended actions so it does not hide the reason for a warning.

## Application preflight

Check service initialization, running status, authentication and PHP client availability. Discovery may inspect safe marker files for common frameworks, but should not read source secrets or edit application files.

## Exportable diagnostics

Provide a preview that lists included fields. Redact credentials and tokens; exclude application payload, session identifiers, private keys and unrelated files. Record export events without recording the bundle's sensitive contents. Diagnostics export remains unimplemented.
