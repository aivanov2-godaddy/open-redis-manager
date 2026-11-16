# Monitoring, health and diagnostics

## Metrics

The installed cPanel page requests one bounded Redis-compatible INFO sample for memory/current peak, connected clients, uptime, operations per second, and keyspace hits/misses. Values are normalized to numeric fields. The broker atomically retains the latest sample in a root-owned `0600` file beside the account manifest; cPanel accounts cannot read or modify it. When the service stops or a live probe fails, the page shows that sample as stale with its UTC capture time. Latest samples expire after 30 days.

A separate per-account `orm-metrics-collect@<account>.timer` invokes the fixed collector hourly as the cPanel account, through the local Unix socket. It runs only while the account's ORM instance is active. Each successful sample updates that hour's bucket in a root-owned `0600` history file protected by a root-owned lock and atomic replacement. History is capped at 720 hourly records, 256 KiB and 30 days. The cPanel page offers 24-hour and 7-day charts for memory, connected clients and hit ratio. Values are numeric allowlist fields; history requests accept only those two fixed ranges and return at most 24 or 168 points. If the timer cannot be scheduled, the page reports that; it does not silently present an empty range as working collection. The reference also mentions latency, which is not currently sampled. Never equate a high health score with an uptime guarantee.

## Health score

Use understandable sub-signals: service availability, memory pressure, connection saturation, cache hit ratio, uptime and authentication posture. A score should link to underlying observations and recommended actions so it does not hide the reason for a warning.

## Application preflight

The installed cPanel page reports whether the instance is initialized, whether its service is running, and whether account-scoped connection details are available. It labels application connectivity unverified because ORM does not inspect app configuration or test the site's selected PHP runtime or client extension. The optional application scan uses bounded, fixed marker paths from authenticated cPanel domain metadata. It reports only supported app names, reads no file contents, and makes no application changes. A marker is not proof that a site is configured to use the cache.

## Exportable diagnostics

The authenticated cPanel page provides a **Support diagnostics** section with a collapsed JSON preview and an explicit download link. It runs only after cPanel LiveAPI identity matches the local broker's peer identity. The export contains a schema version, UTC generation time, normalized instance state, allowlisted workload preset and bounded configuration, fixed connection-mode flags, and the latest bounded metric sample with its stale/retained flags. A missing or failed broker response becomes `unavailable` or `null`; raw errors are never exported.

The report is assembled in memory for the current page request. ORM does not save the report or create a separate export log. It excludes account names, hostnames, socket/filesystem paths, credentials, tokens, Redis keys and values, application payloads and sessions, logs, and raw command output. The download uses a fixed UTC timestamp filename, `Cache-Control: no-store`, and `X-Content-Type-Options: nosniff`. It accepts only the exact `GET ?orm_diagnostics=download` route. The report builder copies only allowlisted fields from the broker response and rejects out-of-range settings or metric shapes.
