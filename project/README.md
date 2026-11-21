# Project plan

This folder keeps local copies of the GitHub planning artifacts. The milestone and issues are now live in the repository; the issue files preserve their initial acceptance criteria. The PR draft prepares the initial code review.

## Proposed milestone

**0.1.0 — Safe cPanel integration foundation** ([milestone #1](https://github.com/aivanov2-godaddy/open-redis-manager/milestone/1))

Goal: turn the UI prototype into an installable, least-privilege cPanel/WHM plugin on a supported test server. Acceptance includes account isolation, documented supported OS/cPanel matrix, Redis/Valkey discovery, safe lifecycle operations, CSRF/ACL checks, uninstall preservation, and a disposable-host validation record.

## Follow-on milestone

**0.2.0 — Operations and lifecycle completeness** ([milestone #2](https://github.com/aivanov2-godaddy/open-redis-manager/milestone/2))

Goal: implement the remaining documented administration workflows after the safe cPanel foundation. This milestone covers actionable health guidance, security/abuse reports, an audit viewer, a signed versioned updater, verified fleet aggregates with bounded batch snapshots, and configurable global defaults for new Redis/Valkey instances. Each implementation still needs its own security review and tests; it does not establish production host support.

## Issue drafts

- [#1 — Establish cPanel and WHM plugin entry points](https://github.com/aivanov2-godaddy/open-redis-manager/issues/1) ([draft](issues/01-plugin-entry-points.md))
- [#2 — Add account-isolated Redis and Valkey service adapter](https://github.com/aivanov2-godaddy/open-redis-manager/issues/2) ([draft](issues/02-backend-adapter.md))
- [#3 — Implement cPanel lifecycle, configuration and connection helper](https://github.com/aivanov2-godaddy/open-redis-manager/issues/3) ([draft](issues/03-cpanel-workflow.md))
- [#4 — Implement WHM fleet operations and recovery](https://github.com/aivanov2-godaddy/open-redis-manager/issues/4) ([draft](issues/04-whm-workflow.md))
- [#5 — Add backup, restore and bounded monitoring](https://github.com/aivanov2-godaddy/open-redis-manager/issues/5) ([draft](issues/05-operations.md))
- [#6 — Add package, reseller, policy and branding controls](https://github.com/aivanov2-godaddy/open-redis-manager/issues/6) ([draft](issues/06-provider-controls.md))
- [#7 — Build disposable cPanel integration environment and release gates](https://github.com/aivanov2-godaddy/open-redis-manager/issues/7) ([draft](issues/07-validation.md))
- [#52 — Complete WHM fleet recovery and aggregate visibility](https://github.com/aivanov2-godaddy/open-redis-manager/issues/52) — closed after the guarded recovery and page-scoped fleet-count implementation ([historical draft](issues/08-whm-recovery-aggregates.md))
- [#67 — Build actionable cPanel health guidance](https://github.com/aivanov2-godaddy/open-redis-manager/issues/67) — completed by [PR #73](https://github.com/aivanov2-godaddy/open-redis-manager/pull/73) ([draft](issues/09-health-guidance.md))
- [#69 — Add a WHM audit viewer and export](https://github.com/aivanov2-godaddy/open-redis-manager/issues/69) ([draft](issues/10-audit-viewer.md))
- [#70 — Implement a signed, versioned WHM updater](https://github.com/aivanov2-godaddy/open-redis-manager/issues/70) ([draft](issues/11-signed-updater.md))
- [#68 — Add fleet aggregates and batched snapshot operations](https://github.com/aivanov2-godaddy/open-redis-manager/issues/68) ([draft](issues/12-fleet-aggregates.md))
- [#71 — Add WHM security and abuse reporting](https://github.com/aivanov2-godaddy/open-redis-manager/issues/71) ([draft](issues/13-security-abuse-reports.md))
- [#95 — Add configurable WHM defaults for new Redis and Valkey instances](https://github.com/aivanov2-godaddy/open-redis-manager/issues/95) ([draft](issues/14-whm-global-defaults.md))
- [#143 — Add optional signed provider automation events](https://github.com/aivanov2-godaddy/open-redis-manager/issues/143) ([draft](issues/15-provider-events.md))
- [#159 — Add selectable safe WHM Redis diagnostic command classes](https://github.com/aivanov2-godaddy/open-redis-manager/issues/159) ([draft](issues/16-whm-diagnostic-console.md))

Issue #2 now has read-only backend discovery, a WHM root-only backend choice for new instances, and a closed peer-credential broker for per-account lifecycle, live metrics, fixed setup presets and bounded configuration. PR #16 merged the initial lifecycle slice; live disposable cPanel validation is still required before production use.

## Pull request plan

Open a feature branch and pull request for each coherent implementation increment after the corresponding issue is created. The first PR should deliver the prototype, docs, and UX screenshots; later PRs should ship one privileged boundary at a time. PRs require actual validation on the stated runtime and must disclose any screen that remains mock data.

## Current status (2026-11-21)

- Upstream repository: public. `main` tracks the upstream default branch; implementation work is reviewed through feature branches and pull requests.
- Milestones #1 and #2 exist on GitHub. The 0.1.0 release gates remain open in issues #1 and #7. PRs #99–#102 added the signed no-migration contract and source provenance, exact version/manifest checks, and post-apply WHM registration plus broker-state/socket readiness checks. PR #104 verifies interrupted apply recovery state and fail-closed retries in Linux CI; PR #106 added the guarded recovery command. PRs #113–#114 added and validated the exact managed-v1 upgrade and its interruption rollback. Issue #70 remains open for production signing authority/distribution and source-matched disposable-host validation. Issue #95 tracks configurable WHM defaults for new Redis/Valkey instances. Check live issue state before treating any planning link here as open or closed.
- Recent merged work includes PR #57 (validation and release-gate documentation), #58 (ENOSPC rollback coverage), #59 (ORM brand icon), #60 (isolated fresh-install and rollback coverage), #64 (optional account-scoped Redis AUTH), #65 (AUTH release gates), #66 (feature coverage catalog), #72 (0.2 feature backlog), #73 (cPanel health guidance), #98 (native-size cPanel launcher icon), #99–#102 (signed updater contracts and post-apply checks), #103–#106 (release-gate, interrupted-update, and recovery work), #113–#114 (managed-v1 migration), #116 (cPanel-specific transparent icon rendering), and #176 (scan-guided config rebuild recovery).
- The repository includes a manual development installer, cPanel/WHM entry points, an account-bound broker, instance lifecycle/configuration, metrics, backups and restore, package/reseller policy, provider branding, application discovery, guarded migration, root-only diagnostics, a fixed recovery scan/start/config-rebuild action, a report-only WHM security review, an audit viewer, and signed asynchronous WHM updates. The config rebuild is limited to an intact manifest and safely readable existing config, preserves only validated settings/AUTH, and does not start the service. The standalone prototype UI uses sample data.
- Linux CI and fixture tests cover important broker and packaging paths, including fresh-install success/rollback in an isolated mock cPanel root. Live evidence includes account identity, one exact managed-v1 upgrade, and cPanel icon registration refresh; records state their narrow scope. Live fresh install, lifecycle, ACLs across supported releases, restore, Redis-to-Valkey migration, recovery, uninstall, CloudLinux/CageFS and failure-injection behavior remain release gates. No ORM-supported production host matrix is established.
- The [host compatibility and validation matrix](../docs/validation/compatibility-matrix.md), [sanitized validation record template](../docs/validation/record-template.md), and [unreleased release notes](../docs/release-notes.md) track the gap between implemented code and validated deployment support.
- User-supplied Redis commands remain unsupported. Audit the live issue list before planning additional milestone #2 work; issue #71 covers the report-only security feature. A read-only Redis 6.2.24 probe confirms its optional auth counter is absent. The authenticated ORM-to-WHM report form and audit flow passed on the rc.8 candidate; Valkey and broader supported-version/host coverage remain open.
- Application connection guides document values and examples; ORM does not configure application files. WHM applies manually staged signed file releases for exact v3 installs. There is no automatic release feed or production signing service; AppConfig changes, first-time bootstrap of older installs, upgrades outside the exact tested managed-v1 baseline, and the remaining live-host validation remain release gates. See the [update lifecycle guide](../docs/guides/update-lifecycle.md).

- [#161 — Validate selectable WHM diagnostics on disposable cPanel](https://github.com/aivanov2-godaddy/open-redis-manager/issues/161) ([draft](issues/17-whm-diagnostics-live-validation.md))
