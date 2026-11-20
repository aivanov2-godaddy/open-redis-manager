# Unreleased development notes

**Updated:** 2026-11-20
**Release:** none published; the project is targeting milestone 0.1.0.

These notes distinguish repository implementation from deployment readiness. A feature can exist in the code while remaining experimental for cPanel deployments.

## Status meanings

- **Implemented:** the documented behavior exists in the repository. This label alone does not establish production readiness.
- **Experimental:** a working implementation exists, but its end-to-end behavior or supported host matrix has not passed the disposable cPanel release gate.
- **Planned:** the behavior is not implemented in the repository.

## Implemented

- WHM security reports now support separate root-owned, report-only thresholds for eviction deltas, average operations per second, and optional authentication-failure deltas. All thresholds default to disabled; a threshold only changes finding severity. Automated enforcement remains unimplemented. See the [threshold guide](guides/security-report-thresholds.md).

- Standalone sample-data PHP prototype for reviewing layout and workflows; it does not connect to Redis.
- Application guides and copyable connection examples; ORM does not edit application files or establish client compatibility for a specific host.
- Broker-backed Redis/Valkey per-account provisioning, status, bounded configuration, lifecycle controls, metrics, and hourly history.
- Account backups, restore with safety snapshot and rollback attempt, Redis-to-Valkey migration, root-only WHM diagnostics, provider policy controls, and guarded recovery scan/start.
- Advisory cPanel health guidance for service state, configured memory/client limits, and cumulative hit ratio; metric findings pause for missing or stale samples.
- Root-only WHM audit search and normalized JSON export for retained ORM broker and WHM policy events, with bounded journal reads and visible source coverage gaps.
- Account-scoped discovery of existing cPanel EA Podman Redis/Valkey containers, optional PhpRedis PING, safe version reporting, application connection examples, and fixed start/stop/restart controls that call cPanel's EA Podman tool as the owning account. cPanel retains package configuration and container data ownership.
- cPanel Jupiter now registers fresh v4 direct-path SVG icons and matching 48×48 PNG fallbacks rendered from the approved ORM mark. Install, upgrade, and uninstall regenerate the theme sprite and synchronize its hash for browser cache refresh. The README logo is unchanged. See the [icon registration record](validation/records/2026-11-20-cpanel-icon-registration.md).
- On-demand fleet status and fresh scheduled-metrics aggregates, plus sequential create/restore batches capped at two visible running accounts with independent audited outcomes.
- Root-only WHM signed-release preview and apply for manually staged bundles: signature and digest verification, explicit conflict-free confirmation, candidate-bound asynchronous transaction jobs, bounded status, and recovery-required reporting. Existing installs must have an exact v3 manifest; v1/v2 manifest adoption only succeeds for an exact match. Apply verifies the installed version, complete managed-file manifest, WHM registration, and the broker's prior service state; when active it also checks the root-owned socket type and permissions. Live disposable cPanel validation remains open.
- Offline release bundle builder for clean, version-matched Git checkouts. It signs bounded metadata with an external RSA private key, derives the public key, validates the archive, and refuses dirty source, unsafe key/output paths, and overwriting an existing bundle. It does not automate publishing or key rotation.
- Signed release metadata v2 binds the exact source commit and declares `state_migrations|none`; the verifier and WHM preview reject unsupported state migrations and display both values before confirmation. Persistent-state transforms require a separate reviewed updater path.
- Exact pre-existing root-owned candidate files missing from an installed v3 manifest can be explicitly reviewed and adopted without rewriting them. Preview and apply require matching fixed path, regular-file type, mode, owner, and signed digest; interrupted recovery preserves adopted files while restoring the prior manifest.
- Root-owned unmanifested files that match the signed candidate after CRLF-to-LF normalization can be explicitly reviewed and normalized to the signed bytes. Apply snapshots the original bytes, and interrupted recovery restores them.
- Root-only report-only security review for fresh fleet memory/client/hit-ratio aggregates, bounded evicted-key and processed-command counter deltas, optional backend authentication-failure counter deltas, and recent normalized ORM AUTH management outcomes. Counter rates require compatible consecutive samples with uptime continuity and actual intervals no longer than 26 hours; reports show interval bounds and treat gaps, missing fields, and resets as unknown. Backend authentication counters are anonymous aggregate evidence and do not identify clients or establish an attack. Operation and authentication activity is not classified as abuse. Requests are limited to one per minute and report events contain fixed metadata only; credential-strength findings remain unavailable.
- Version-five root WHM provider policy with validated global defaults and package client/database ceilings. New instances cap generated client and database settings at the effective package limits; later over-cap client increases follow report-only, warn, or enforce mode while unchanged or reduced legacy values remain allowed. Version-one through version-four policies migrate with compatibility ceilings. New version-three instance manifests capture database, retention, and snapshot defaults; Redis/Valkey config and history collection apply them without rewriting existing instances. Metrics history supports 7–90 days within the 2,160-sample and 1 MiB caps.

## Experimental

- Manual development installer, authenticated cPanel/WHM entry points, and root-owned broker integration. Linux CI exercises fresh-install success and rollback with isolated mock cPanel registration utilities; a live cPanel install is still unvalidated.
- Optional cPanel account-level Redis AUTH enable, disable, and password rotation for running ORM instances. Generated passwords are returned once after restart and PING verification; failed verification attempts a configuration and service rollback. WHM-directed credential management and disposable-host validation remain open.
- ORM-managed lifecycle, metrics, backups/restore, migration, WHM diagnostics, provider controls, and recovery behavior remain experimental on cPanel. EA Podman start/stop/restart passed one account-context PHP CLI smoke on one disposable host; the authenticated web form/session flow, cross-account denial matrix, and broader host coverage remain unverified.
- The cPanel health guidance thresholds are heuristics and remain unverified on a supported disposable host.
- The WHM security report is not validated on a supported disposable host; it does not enforce policy and does not claim to detect Redis login attacks, weak passwords, or password reuse.
- Host support across cPanel/WHM versions, supported OS releases, internal PHP versions, EasyApache/Alt-PHP, handlers, CageFS, and PHP Selector.

Three live cPanel account-identity smoke runs passed during private testing. The latest identity run was read-only; its deployed source revision was not matched to the current checkout, and it did not detect a Redis/Valkey backend at the supported common paths. A separate exact managed-v1 package upgrade passed on one owner-designated cPanel test system; that result is recorded independently and does not establish broad update or host support. The identity runs do not validate service lifecycle, ACL behavior across releases, backup/restore, Redis-to-Valkey migration, recovery, or uninstall. See the [host validation matrix](validation/compatibility-matrix.md).

## Planned

- Automatic release discovery/download, hosted signing authority and key rotation operations, and automated first-time migration of older installations into the v3 updater baseline.
- Automatic whole-fleet backup/restore/repair batches; current WHM snapshot batches intentionally cover at most two selected accounts per request.
- The Redis 6.2.24 test service lacks the optional ACL auth-failure counter while exposing eviction and command counters; this direct read-only probe does not test ORM collection. Valkey/version coverage, counter-reset behavior on the supported matrix, and the live report-only flow remain open. See the [sanitized probe record](validation/records/2026-11-20-redis-6.2-security-counter-probe.md).
- A production-supported cPanel/OS/PHP matrix. No ORM host combination has completed the full validation gate.

## Release gate

Do not promote this build as production-ready until the candidate environments and scenarios in the [compatibility and validation matrix](validation/compatibility-matrix.md) have passed, sanitized records have been reviewed, and the exact release commit has completed required CI and secret scans. Use the [validation record template](validation/record-template.md). Current automated and live evidence is summarized in the matrix.
