# WHM security report thresholds

## Scope

The WHM security and abuse review is an advisory report. Root can configure thresholds for measured evictions, average operations per second, and backend authentication-failure counter deltas. A threshold changes the finding severity to **warning** when the observed maximum is equal to or greater than the configured value.

All thresholds default to zero, which disables threshold classification. Thresholds are stored separately from provider capacity policy in a root-owned, mode-0600 policy file. They do not change Redis/Valkey configuration, account access, provider enforcement mode, or service state. ORM does not apply automated enforcement or remediation for these abuse signals.

## Evidence and interpretation

- **Evictions:** the threshold is a counter delta per sampled interval. The interval is based on the actual compatible samples and can range from 1 second to 26 hours. Each report includes its observed interval bounds.
- **Operations:** the threshold is the maximum observed average number of processed commands per second over the measured interval.
- **Authentication failures:** the threshold is a counter delta per sampled interval when the backend exposes the optional authentication-failure INFO field. Unsupported fields, missing baselines, resets, and incomplete intervals stay unknown.

## EA Podman coverage

The WHM report includes separate EA Podman Redis/Valkey coverage and counter findings. It shows discovered, sampled, unmeasured, and skipped counts without combining these containers with ORM-managed account totals. The collector stores a root-owned, mode-0600 baseline at `/var/lib/orm-podman/counter-baseline.json` containing SHA-256 digests of Redis/Valkey `run_id` values and only the allowlisted counters. Digests are linkable pseudonymous state, not anonymous data. Raw run IDs, account names, container names, socket paths, and INFO bodies are never persisted or returned to WHM. The baseline is limited to 256 process entries and 256 KiB; it is protected by a root-owned mode-0600 lock, and stale windows over 26 hours are not measured.

Counter findings are measured only when both scans are complete, the exact same unique server-ID set appears, timestamps advance within 26 hours, and every required counter is monotonic. Process-set changes, resets, invalid state, missing identity, or incomplete scans produce an explicit unknown finding; partial scans never replace the baseline. Eviction deltas and operations per second are maximum per-process values; operations per second are rounded down to a whole number, matching ORM-managed metrics and avoiding upward threshold rounding. Optional authentication-failure deltas remain unknown if any matched process lacks that INFO field. Thresholds are report-only and default to disabled. These aggregates do not identify an account, container, or client.

These measurements are anonymous fleet aggregates. They do not identify which account or client produced the maximum, distinguish mistakes from attacks, or prove abuse. A threshold warning is a review prompt, not an incident finding. Do not treat missing or stale evidence as zero.

The report remains rate-limited to one generation per minute. Changing the threshold policy requires an authenticated root WHM POST and is recorded as a fixed metadata-only audit event. The report and audit record do not contain secrets, cache keys, values, or client identities.

## Validation

Automated tests cover default-disabled thresholds, exact and below-threshold comparisons, malformed/unavailable policy handling, process continuity, privacy boundaries, and normalized audit records. One Redis 6.2.24 cPanel Podman cache exposed eviction and processed-command counters but not the optional authentication-failure counter; this is a single-host observation, not a compatibility guarantee. See the [compatibility matrix](../validation/compatibility-matrix.md).
