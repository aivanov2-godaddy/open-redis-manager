# Add fleet aggregates and bounded batched snapshot operations

Live issue: [#68](https://github.com/aivanov2-godaddy/open-redis-manager/issues/68), milestone 0.2.0.

Add verified fleet-wide running/managed counts, memory/client aggregates and alert summaries, followed by bounded fleet backup/restore jobs with per-account outcomes.

Acceptance:

- Derive account identity only from trusted manifests and account records; cap and paginate work.
- Isolate per-account failures and show partial or unavailable data honestly.
- Preserve explicit restore confirmation and safety snapshots.
- Rate-limit, audit, and test concurrent requests and injected failures.
