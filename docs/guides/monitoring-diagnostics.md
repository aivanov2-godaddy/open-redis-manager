# Monitoring, health and diagnostics

## Metrics

The installed cPanel page currently requests one live Redis-compatible INFO sample for memory/current peak, connected clients, uptime, operations per second, and keyspace hits/misses. Values are fetched on page load, normalized to numeric fields, and are not retained. A failed sample is shown as unavailable. The public reference also names latency and trend history; those remain unimplemented. Future history must label its interval and time range, mark busy/stale samples, and never equate a high health score with an uptime guarantee.

## Health score

Use understandable sub-signals: service availability, memory pressure, connection saturation, cache hit ratio, uptime and authentication posture. A score should link to underlying observations and recommended actions so it does not hide the reason for a warning.

## Application preflight

Check service initialization, running status, authentication and PHP client availability. Discovery may inspect safe marker files for common frameworks, but should not read source secrets or edit application files.

## Exportable diagnostics

Provide a preview that lists included fields. Redact credentials and tokens; exclude application payload, session identifiers, private keys and unrelated files. Record export events without recording the bundle's sensitive contents.
