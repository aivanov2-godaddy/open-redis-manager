# Build actionable cPanel health guidance

Live issue: [#67](https://github.com/aivanov2-godaddy/open-redis-manager/issues/67), milestone 0.2.0.

Add metric-backed findings for memory pressure, low hit ratio, unavailable service/runtime paths, stale metrics, and other verified checks.

Acceptance:

- Emit findings only when required inputs are available; show severity, evidence, time window/freshness, and a safe remedy.
- Do not claim application connectivity without performing a real supported check.
- Cover normal, warning, unavailable, and stale states in unit/UI tests.
- Document thresholds and known limitations.
