# Implement a signed, versioned WHM updater

Live issue: [#70](https://github.com/aivanov2-godaddy/open-redis-manager/issues/70), milestone 0.2.0.

The signed file-update flow shipped in PRs #80–#92. Follow-up PRs #99–#102 require a signed no-migration declaration and exact source commit, verify installed version and complete manifest state, and check WHM registration plus broker state/socket readiness after apply. PR #104 covers interrupted apply in Linux CI. PR #106 added the guarded recovery command and fixture coverage for journal validation, backups, unknown target digests, idempotent retries, and preserved account/Redis state. PRs #113–#114 added and exercised a safe upgrade from the exact managed-v1 baseline, including rollback and interrupted-install coverage. The offline bundle builder and documented key custody, rotation, provenance, publication, and staging procedures are in the [release signing guide](../../docs/guides/release-signing.md). See the [update lifecycle guide](../../docs/guides/update-lifecycle.md).

Remaining acceptance:

- The current signed-update contract is deliberately file-only: release metadata signs `state_migrations|none`, and WHM preview rejects unsupported migration declarations. Any persistent ORM state transform needs a separately reviewed, versioned transaction with backup, rollback, and interruption recovery.
- Production signing is not configured: assign the release authority and key custodian, provision and rotate the production key outside this repository, and establish immutable public release publication/distribution. Staging on servers remains manual and root-controlled.
- Validate signed-update success, conflict rejection, rollback, process interruption/recovery, preserved instance state, WHM/cPanel registration, and broker readiness on a source-matched disposable cPanel host. The exact managed-v1 package upgrade passed on one test cPanel system; it does not complete the broader host, update, or lifecycle gate in issue #7.
- Do not claim host support without disposable validation.
