# WHM security report thresholds

## Scope

The WHM security and abuse review is an advisory report. Root can configure thresholds for measured evictions, average operations per second, and backend authentication-failure counter deltas. A threshold changes the finding severity to **warning** when the observed maximum is equal to or greater than the configured value.

All thresholds default to zero, which disables threshold classification. Thresholds are stored separately from provider capacity policy in a root-owned, mode-0600 policy file. They do not change Redis/Valkey configuration, account access, provider enforcement mode, or service state. ORM does not apply automated enforcement or remediation for these abuse signals.

## Evidence and interpretation

- **Evictions:** the threshold is a counter delta per sampled interval. The interval is based on the actual compatible samples and can range from 1 second to 26 hours. Each report includes its observed interval bounds.
- **Operations:** the threshold is the maximum observed average number of processed commands per second over the measured interval.
- **Authentication failures:** the threshold is a counter delta per sampled interval when the backend exposes the optional authentication-failure INFO field. Unsupported fields, missing baselines, resets, and incomplete intervals stay unknown.

## EA Podman coverage

The WHM report includes a separate EA Podman Redis/Valkey coverage finding from the root-owned scheduled snapshot. It shows discovered, sampled, unmeasured, and skipped counts and does not combine these containers with ORM-managed account totals. A missing, stale, invalid, or partial snapshot is reported as unknown. A separate `podman_counter_rates_unknown` finding is always shown: the six allowlisted Podman counters are a single anonymous aggregate snapshot, which cannot establish that the same Redis/Valkey server processes were present across samples. Podman eviction, operation-rate, and authentication-failure deltas and thresholds are not evaluated. The report records this gap under `ea_podman_counter_rates`; it never interprets cumulative totals as rates.

Computing trustworthy Podman deltas would require retaining cross-sample process-continuity data. Any such baseline would be linkable pseudonymous state even if it withheld account and container names, so it needs a separate privacy and security review before implementation. The current report does not retain per-process identities or counters.

These measurements are anonymous fleet aggregates. They do not identify which account or client produced the maximum, distinguish mistakes from attacks, or prove abuse. A threshold warning is a review prompt, not an incident finding. Do not treat missing or stale evidence as zero.

The report remains rate-limited to one generation per minute. Changing the threshold policy requires an authenticated root WHM POST and is recorded as a fixed metadata-only audit event. The report and audit record do not contain secrets, cache keys, values, or client identities.

## Validation

Automated tests cover default-disabled thresholds, exact and below-threshold comparisons, malformed/unavailable policy handling, private root-owned storage, symlink rejection, and normalized audit records. One Redis 6.2.24 cPanel Podman cache exposed eviction and processed-command counters but not the optional authentication-failure counter; this is a single-host observation, not a compatibility guarantee. See the [compatibility matrix](../validation/compatibility-matrix.md).
