# Add WHM security and abuse reporting

Live issue: [#71](https://github.com/aivanov2-godaddy/open-redis-manager/issues/71), milestone 0.2.0.

Report supported memory, client, eviction, operation-rate, and authentication signals with explicit evidence and remediation.

Acceptance:

- Keep abuse findings report-only. The separate WHM report/warn/enforce provider policy controls provisioning and package limits; it does not automatically remediate abuse findings.
- Rate-limit and redact every event; include a bounded time window and evidence for each finding.
- Do not inspect or claim detection of weak/reused passwords without a safe, verifiable design.
- Test thresholds, unavailable inputs, rate limits, false/unavailable states, and secret redaction.

## Progress (2026-11-16)

- Added a root-WHM report-only review for fresh fleet memory/client/hit-ratio aggregates, bounded eviction and processed-command counter deltas, and normalized AUTH management outcomes in a bounded 24-hour window. Report generation is limited to one per minute and writes a fixed metadata-only audit event.
- New root-owned security counter snapshots preserve the existing cPanel metrics and hourly-history schemas. Eviction and operation rates are calculated only from monotonic counters with uptime continuity and an actual one-second-to-26-hour interval; missing baselines, counter resets, missing sources, and longer gaps remain unknown. Evidence includes sample-window bounds. Operation rates are descriptive load evidence; abuse findings remain advisory and do not trigger automated enforcement or remediation. The reference documentation describes abuse detection as report-only; its separate provider policy modes govern provisioning and package limits.
- The broker optionally detects the backend `acl_access_denied_auth` INFO counter at runtime and tracks its bounded delta separately from eviction and operation counters. Backends without the field remain unknown while supported rates stay available. Counter decreases, restarts, missing baselines, and long gaps remain unknown. The report exposes only account-level aggregate evidence and does not identify clients or claim attacks.
- The report omits account names and secret values and does not inspect credential strength/reuse. Remaining acceptance work: verify counter behavior on supported Redis and Valkey releases, verify unknown coverage on older releases, and validate the rendered WHM flow on a disposable supported host.

## Progress (2026-11-20)

- A read-only PhpRedis `INFO server` / `INFO stats` probe against the owner-designated cPanel EA Podman Redis 6.2.24 test service found `evicted_keys` and `total_commands_processed` present and the optional `acl_access_denied_auth` field absent. Only field presence and the server version were recorded; no counter values, keys, or payloads were read into the record, and no Redis write was performed. See the [sanitized probe record](../../docs/validation/records/2026-11-20-redis-6.2-security-counter-probe.md).
- This is backend field-availability evidence, not an ORM metrics-collection or rendered WHM report test. Existing broker fixtures cover missing authentication-counter behavior while preserving eviction/operation rates. Valkey behavior and the full supported-version matrix remain unvalidated.

## Progress (2026-11-21)

- The source-matched `0.1.0-rc.8` candidate passed the authenticated root-WHM SSO report flow on cPanel & WHM `138.0 (build 27)`: the form rendered, the report POST returned its generated UTC section, and a normalized `security.report` success event was verified. The run intentionally consumed the one-minute report throttle and wrote one metadata-only audit event; it did not change thresholds/backend policy or read Redis keys, values, or secrets. See the [sanitized live record](../../docs/validation/records/2026-11-21-whm-security-report-live.md).
- This HTTP smoke does not validate every finding or constitute browser visual review. Valkey and the broader supported-version/host matrix remain unvalidated; the feature remains partial until those checks are complete.
