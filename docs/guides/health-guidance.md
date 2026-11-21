# cPanel health guidance

The cPanel page presents advisory findings from the authenticated account status and metrics already returned by the ORM broker. Findings do not change configuration or service state. They do not test an application's connection to Redis/Valkey and are not a performance guarantee.

## Current checks

| Check | Advisory condition | Suggested review |
|---|---|---|
| Service state | The service is stopped or failed, or status cannot be verified. | Start a deliberately stopped service; for a failed or unavailable service, verify status and contact the provider. |
| Memory | Current Redis `used_memory` is at least 85% of the configured memory ceiling. | Review cache growth and eviction behavior. A larger limit may require provider approval. `used_memory` is a Redis counter and is not a measurement of total process RSS. |
| Connected clients | Current connected clients are at least 85% of the configured `maxclients`. | Review application connection pooling and provider limits before raising the ceiling. |
| Cumulative hit ratio | `keyspace_hits / (keyspace_hits + keyspace_misses)` is below 50% after at least 100 lookups. | Review whether the application stores and reuses the expected cache entries. The counters are cumulative since the current process started and reset when it restarts. |

The 85% and 50% values are ORM heuristics, not Redis/Valkey limits or vendor recommendations. They are deliberately described as review thresholds. The page suppresses metric findings when metrics are unavailable or marked stale; saved values remain visible in the metrics area with their sample timestamp. Too few lookups produce no hit-ratio finding.

The page reports the service state and metric sample independently. It does not infer a successful application connection from an initialized/running cache, helper text, or a detected application marker. It does not currently detect disabled language extensions or score trends from hourly history.

## Advisory health score

For a running instance with a fresh broker sample, the page shows an advisory score from four equally weighted checks:

1. The account-scoped broker verifies that the service is running.
2. Current Redis `used_memory` is below 85% of the configured memory ceiling.
3. Current connected clients are below 85% of the configured client ceiling.
4. The cumulative keyspace hit ratio is at least 50%, after at least 100 lookups.

The score is the percentage of passed checks among the checks that could be evaluated. The page also shows evidence coverage (the number of evaluated checks out of four). An insufficient hit sample, invalid/missing setting, or missing metric is unknown and is excluded from both the result and coverage; it is never silently treated as a pass. A number is shown only when at least three checks are verifiable. A stopped, changing, unconfigured, stale, or unavailable service state has no numeric score.

`Strong signals` means 90–100, `Review suggested` means 70–89, and `Needs attention` means below 70. These labels describe only the listed checks. Uptime is shown as context and is not scored because a long process lifetime does not prove good cache behavior. AUTH remains optional for ORM's account-private Unix socket and is not treated as a health failure when disabled. Application connectivity, PHP extensions, trends, latency, and performance are not verified or scored. The score is a transparent heuristic, not a vendor health guarantee.

## Implementation and verification

The rules and score are implemented in [`HealthGuidance.php`](../../src/Orm/Cpanel/HealthGuidance.php) and rendered by the installed cPanel entry point. The unit/page/package checks are in [`cpanel-health-guidance.php`](../../tests/cpanel-health-guidance.php). These tests verify threshold boundaries, score coverage, small samples, stale/missing metrics, stopped state, unknown status and packaging registration. Live cPanel behavior remains subject to the [disposable-host validation gate](../validation/compatibility-matrix.md).
