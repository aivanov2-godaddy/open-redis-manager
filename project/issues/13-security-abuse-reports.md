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
- This HTTP smoke does not validate every finding or constitute browser visual review. The Valkey field probe below does not exercise cPanel EA Podman, ORM collection, or the WHM report with Valkey. The broader supported-version/host matrix remains unvalidated; the feature remains partial until those checks are complete.
- A read-only probe of an isolated standalone Valkey 8.1.10 process found `evicted_keys`, `total_commands_processed`, and `acl_access_denied_auth` fields in `INFO stats`. No values, keys, or payloads were retained; the process and temporary files were removed and cleanup verified. This did not exercise the cPanel EA Podman integration or ORM collector. A Valkey regression fixture now checks that if the optional auth field is missing, eviction and operation evidence remain available and auth stays unknown. See the [sanitized Valkey probe](../../docs/validation/records/2026-11-21-valkey-security-counter-probe.md).

## EA Podman integration progress (2026-11-21)

The WHM fleet summary reads root-owned snapshots for verified ORM-managed accounts and does not probe live services while rendering fleet rows or reports. The cPanel Podman discovery path is account-scoped and must not be treated as a trusted source for WHM report counters: account-submitted values can be forged, and Podman-only accounts do not have an ORM manifest.

The working-tree implementation adds a separate bounded root systemd sampler for exact EA Redis/Valkey socket names, owner-verified paths, peer-UID checks, read-only `INFO ALL`, allowlisted counters, and an atomic root-owned anonymous snapshot. It caps account enumeration, directory entries, per-account containers, probe count, reply size, and request time. A missing optional `ea-podman.d` directory is treated as zero containers; unsafe or unreadable paths remain unverified. WHM reads and validates the snapshot only, shows aggregate coverage separately from ORM-managed accounts, and reports unavailable or partial coverage as unknown. No Podman identifiers or raw INFO data are stored. Abuse findings remain advisory and report-only.

The scheduled collection, strict snapshot schemas, separate WHM coverage, and baseline fixtures are implemented in the current working tree but are not yet merged. Podman counter deltas, reset-aware rates, and configurable report thresholds are still open. The collector's Linux socket test skips on this Windows development host. Remaining release gates are Linux hostile-path and bounds tests, package/uninstall/rollback checks, source-matched disposable cPanel validation of the timer and Redis/Valkey sockets (including peer credentials and collection duration), and review of the old signed-updater compatibility path. The existing Redis PING and EA Podman lifecycle smokes do not validate this new root sampler.
