# Monitoring, health and diagnostics

## Metrics

The public reference names latency, memory/current peak, connections, uptime, command activity and trend history. The feature inventory also includes cache hits/misses. ORM should label the measurement interval and time range, indicate busy/stale samples and never equate a high health score with an uptime guarantee.

## Health score

Use understandable sub-signals: service availability, memory pressure, connection saturation, cache hit ratio, uptime and authentication posture. A score should link to underlying observations and recommended actions so it does not hide the reason for a warning.

## Application preflight

Check service initialization, running status, authentication and PHP client availability. Discovery may inspect safe marker files for common frameworks, but should not read source secrets or edit application files.

## Exportable diagnostics

Provide a preview that lists included fields. Redact credentials and tokens; exclude application payload, session identifiers, private keys and unrelated files. Record export events without recording the bundle's sensitive contents.
