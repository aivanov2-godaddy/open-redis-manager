# Add configurable WHM defaults for new Redis and Valkey instances

**GitHub issue:** [#95](https://github.com/aivanov2-godaddy/open-redis-manager/issues/95)
**Milestone:** [0.2.0 — Operations and lifecycle completeness](https://github.com/aivanov2-godaddy/open-redis-manager/milestone/2)

## Goal

Allow the root WHM administrator to choose bounded global Redis/Valkey defaults that apply to new ORM-managed instances, while preserving current package limits and existing account data.

## Acceptance criteria

- WHM displays and saves default memory (8–64 MiB), an allowlisted eviction policy, database count (1–16), package client/database ceilings, snapshot retention (2–3), and metrics-history retention (7–90 days).
- PHP storage and the root-owned Perl broker reader validate the same versioned policy and reject malformed or unsafe values.
- New instances capture their effective database, snapshot, and history defaults; workload profiles and package memory, client, and database ceilings bound provisioning.
- Updating defaults does not rewrite existing instance configuration, manifests, snapshots, or history.
- Metrics history prunes using the instance-recorded retention while retaining fixed sample/byte bounds and root-owned file permissions.
- WHM writes remain protected by root authorization, session/CSRF checks, and normalized metadata-only audit events.
- Tests and operator documentation cover defaults, bounds, migration, fail-closed behavior, new-instance application, existing-instance preservation, retention pruning, and UI authorization.

## Validation boundary

Automated tests can verify schema, broker behavior, and packaging. Do not claim support for a live cPanel/WHM host until issue #7's source-matched disposable-host validation gate passes.
