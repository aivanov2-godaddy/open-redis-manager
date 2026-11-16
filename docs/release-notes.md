# Unreleased development notes

**Updated:** 2026-11-16
**Release:** none published; the project is targeting milestone 0.1.0.

These notes distinguish repository implementation from deployment readiness. A feature can exist in the code while remaining experimental for cPanel deployments.

## Status meanings

- **Implemented:** the documented behavior exists in the repository. This label alone does not establish production readiness.
- **Experimental:** a working implementation exists, but its end-to-end behavior or supported host matrix has not passed the disposable cPanel release gate.
- **Planned:** the behavior is not implemented in the repository.

## Implemented

- Standalone sample-data PHP prototype for reviewing layout and workflows; it does not connect to Redis.
- Application guides and copyable connection examples; ORM does not edit application files or establish client compatibility for a specific host.
- Broker-backed Redis/Valkey per-account provisioning, status, bounded configuration, lifecycle controls, metrics, and hourly history.
- Account backups, restore with safety snapshot and rollback attempt, Redis-to-Valkey migration, root-only WHM diagnostics, provider policy controls, and guarded recovery scan/start.
- Advisory cPanel health guidance for service state, configured memory/client limits, and cumulative hit ratio; metric findings pause for missing or stale samples.
- Root-only WHM audit search and normalized JSON export for retained ORM broker and WHM policy events, with bounded journal reads and visible source coverage gaps.
- Account-scoped discovery of existing cPanel EA Podman Redis/Valkey sockets with optional PhpRedis PING, safe version reporting, and application connection examples. cPanel retains container lifecycle and data ownership.
- On-demand fleet status and fresh scheduled-metrics aggregates, plus sequential create/restore batches capped at two visible running accounts with independent audited outcomes.
- Root-only report-only security review for fresh fleet memory/client/hit-ratio aggregates and recent normalized AUTH management outcomes. Requests are limited to one per minute and report events contain fixed metadata only. Eviction-rate, operation-rate, Redis client-authentication failures, and credential-strength findings remain unavailable and are identified as such.

## Experimental

- Manual development installer, authenticated cPanel/WHM entry points, and root-owned broker integration. Linux CI exercises fresh-install success and rollback with isolated mock cPanel registration utilities; a live cPanel install is still unvalidated.
- Optional cPanel account-level Redis AUTH enable, disable, and password rotation for running ORM instances. Generated passwords are returned once after restart and PING verification; failed verification attempts a configuration and service rollback. WHM-directed credential management and disposable-host validation remain open.
- Lifecycle, metrics, backups/restore, migration, Podman discovery, WHM diagnostics, provider controls, and recovery behavior on this disposable cPanel host.
- The cPanel health guidance thresholds are heuristics and remain unverified on a supported disposable host.
- The WHM security report is not validated on a supported disposable host; it does not enforce policy and does not claim to detect Redis login attacks, weak passwords, or password reuse.
- Host support across cPanel/WHM versions, supported OS releases, internal PHP versions, EasyApache/Alt-PHP, handlers, CageFS, and PHP Selector.

Live cPanel identity evidence consists of two smoke runs during private testing. The latest read-only run passed, but the deployed source revision was not matched to the current checkout and no Redis/Valkey backend was detected at the supported common paths. These runs do not validate service lifecycle, ACL behavior across releases, backup/restore, migration, recovery, or uninstall. See the [host validation matrix](validation/compatibility-matrix.md).

## Planned

- A general in-panel updater; the identity-v1 compatibility bridge is narrowly scoped.
- Automatic whole-fleet backup/restore/repair batches; current WHM snapshot batches intentionally cover at most two selected accounts per request.
- Complete eviction and operation-rate abuse signals, plus any safe verified source for Redis client-authentication failures.
- A production-supported cPanel/OS/PHP matrix. No ORM host combination has completed the full validation gate.

## Release gate

Do not promote this build as production-ready until the candidate environments and scenarios in the [compatibility and validation matrix](validation/compatibility-matrix.md) have passed, sanitized records have been reviewed, and the exact release commit has completed required CI and secret scans. Use the [validation record template](validation/record-template.md). Current automated and live evidence is summarized in the matrix.
