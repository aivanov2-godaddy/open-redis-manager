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

## Implementation and verification

The rules are implemented in [`HealthGuidance.php`](../../src/Orm/Cpanel/HealthGuidance.php) and rendered by the installed cPanel entry point. The unit/page/package checks are in [`cpanel-health-guidance.php`](../../tests/cpanel-health-guidance.php). These tests verify threshold boundaries, small samples, stale/missing metrics, stopped state, unknown status and packaging registration. Live cPanel behavior remains subject to the [disposable-host validation gate](../validation/compatibility-matrix.md).
