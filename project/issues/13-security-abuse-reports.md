# Add WHM security and abuse reporting

Live issue: [#71](https://github.com/aivanov2-godaddy/open-redis-manager/issues/71), milestone 0.2.0.

Report supported memory, client, eviction, operation-rate, and authentication signals with explicit evidence and remediation.

Acceptance:

- Default to report-only; require a separate explicit policy for enforcement.
- Rate-limit and redact every event; include a bounded time window and evidence for each finding.
- Do not inspect or claim detection of weak/reused passwords without a safe, verifiable design.
- Test thresholds, unavailable inputs, rate limits, false/unavailable states, and secret redaction.

## Progress (2026-11-16)

- Added a root-WHM report-only review for fresh fleet memory/client/hit-ratio aggregates, bounded eviction and processed-command counter deltas, and normalized AUTH management outcomes in a bounded 24-hour window. Report generation is limited to one per minute and writes a fixed metadata-only audit event.
- New root-owned security counter snapshots preserve the existing cPanel metrics and hourly-history schemas. Rates are calculated only from monotonic counters with uptime continuity and an actual one-second-to-26-hour interval; missing baselines, counter resets, missing sources, and longer gaps remain unknown. Evidence includes sample-window bounds. Operation rates are descriptive load evidence; no arbitrary abuse threshold, enforcement, or remediation is wired to this report.
- The report omits account names and secret values and does not inspect Redis client login attempts or credential strength/reuse. Remaining acceptance work: find a safe verifiable source for client-auth failures if one exists and validate the rendered WHM flow on a disposable supported host.
