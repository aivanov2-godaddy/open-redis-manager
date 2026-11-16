# Add WHM security and abuse reporting

Live issue: [#71](https://github.com/aivanov2-godaddy/open-redis-manager/issues/71), milestone 0.2.0.

Report supported memory, client, eviction, operation-rate, and authentication signals with explicit evidence and remediation.

Acceptance:

- Default to report-only; require a separate explicit policy for enforcement.
- Rate-limit and redact every event; include a bounded time window and evidence for each finding.
- Do not inspect or claim detection of weak/reused passwords without a safe, verifiable design.
- Test thresholds, unavailable inputs, rate limits, false/unavailable states, and secret redaction.

## Progress (2026-11-16)

- Added a root-WHM report-only review for fresh fleet memory/client/hit-ratio aggregates and normalized AUTH management outcomes in a bounded 24-hour window. Report generation is limited to one per minute and writes a fixed metadata-only audit event.
- Partial and unavailable sources are shown as unknown. The report omits account names and secret values, does not inspect Redis client login attempts or credential strength/reuse, and clearly lists eviction-rate and operation-rate signals as not yet measured. No enforcement or remediation is wired to this report.
- Remaining acceptance work: capture eviction and operation-rate metrics with backward-compatible snapshot handling, find a safe verifiable source for client-auth failures if one exists, and validate the rendered WHM flow on a disposable supported host.
