# Implement WHM fleet operations and recovery

## Goal
Provide administrators with fleet visibility and scoped maintenance operations.

## Acceptance criteria
- Account search/filter covers configured, running, stopped and unhealthy services.
- Authorized operators can control a selected account and see the result.
- CLI surface uses a small allowlist by default and records actor/account/command class.
- Recovery scans before proposing repairs and only changes selected affected accounts.
- Audit records include success/failure and omit secrets.
- Backend health and migration readiness are visible without implicit migration.

## Progress

- GitHub issue #4 is closed. PR #19 added a root-only, paginated inventory of configured or unhealthy ORM accounts with normalized service state. Later slices added scoped service controls, snapshots, restore, and migration. The diagnostics implementation in this worktree adds fixed read-only probes for one selected running account, with a numeric/version response allowlist, per-account throttling, and audited results; arbitrary Redis commands remain unsupported. Recovery scans, repairs, and fleet aggregates are tracked in [issue #52](https://github.com/aivanov2-godaddy/open-redis-manager/issues/52).
