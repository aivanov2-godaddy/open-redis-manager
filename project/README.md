# Project plan

This folder keeps local copies of the GitHub planning artifacts. The milestone and issues are now live in the repository; the issue files preserve their initial acceptance criteria. The PR draft prepares the initial code review.

## Proposed milestone

**0.1.0 — Safe cPanel integration foundation** ([milestone #1](https://github.com/aivanov2-godaddy/open-redis-manager/milestone/1))

Goal: turn the UI prototype into an installable, least-privilege cPanel/WHM plugin on a supported test server. Acceptance includes account isolation, documented supported OS/cPanel matrix, Redis/Valkey discovery, safe lifecycle operations, CSRF/ACL checks, uninstall preservation, and a disposable-host validation record.

## Issue drafts

- [#1 — Establish cPanel and WHM plugin entry points](https://github.com/aivanov2-godaddy/open-redis-manager/issues/1) ([draft](issues/01-plugin-entry-points.md))
- [#2 — Add account-isolated Redis and Valkey service adapter](https://github.com/aivanov2-godaddy/open-redis-manager/issues/2) ([draft](issues/02-backend-adapter.md))
- [#3 — Implement cPanel lifecycle, configuration and connection helper](https://github.com/aivanov2-godaddy/open-redis-manager/issues/3) ([draft](issues/03-cpanel-workflow.md))
- [#4 — Implement WHM fleet operations and recovery](https://github.com/aivanov2-godaddy/open-redis-manager/issues/4) ([draft](issues/04-whm-workflow.md))
- [#5 — Add backup, restore and bounded monitoring](https://github.com/aivanov2-godaddy/open-redis-manager/issues/5) ([draft](issues/05-operations.md))
- [#6 — Add package, reseller, policy and branding controls](https://github.com/aivanov2-godaddy/open-redis-manager/issues/6) ([draft](issues/06-provider-controls.md))
- [#7 — Build disposable cPanel integration environment and release gates](https://github.com/aivanov2-godaddy/open-redis-manager/issues/7) ([draft](issues/07-validation.md))
- [#52 — Complete WHM fleet recovery and aggregate visibility](https://github.com/aivanov2-godaddy/open-redis-manager/issues/52) — closed after the guarded recovery and page-scoped fleet-count implementation ([historical draft](issues/08-whm-recovery-aggregates.md))

Issue #2 now has read-only backend discovery, a WHM root-only backend choice for new instances, and a closed peer-credential broker for per-account lifecycle, live metrics, fixed setup presets and bounded configuration. PR #16 merged the initial lifecycle slice; live disposable cPanel validation is still required before production use.

## Pull request plan

Open a feature branch and pull request for each coherent implementation increment after the corresponding issue is created. The first PR should deliver the prototype, docs, and UX screenshots; later PRs should ship one privileged boundary at a time. PRs require actual validation on the stated runtime and must disclose any screen that remains mock data.

## Current status (2026-11-16)

- Upstream repository: public. `main` tracks the upstream default branch; implementation work is reviewed through feature branches and pull requests.
- Milestone #1 and issues #1–#7 plus #52 exist on GitHub. Open issues are #1, #2, #3, #5, #6, and #7. Issues #4 and #52 are closed.
- Recent merged work includes PR #53 (root-only diagnostics), #55 (guarded WHM recovery and page-scoped fleet counts), and #56 (ORM icon redesign). No pull request was open at the time of this update.
- The repository includes a manual development installer, cPanel/WHM entry points, an account-bound broker, instance lifecycle/configuration, metrics, backups and restore, package/reseller policy, provider branding, application discovery, guarded migration, root-only diagnostics, and a fixed recovery scan/start action. The prototype UI uses sample data.
- Linux CI and fixture tests cover important broker and packaging paths, including fresh-install success/rollback in an isolated mock cPanel root. The live cPanel smoke has verified account identity only. Live fresh install, lifecycle, ACLs across supported releases, restore, migration, recovery, uninstall, CloudLinux/CageFS and failure-injection behavior remain release gates. No ORM-supported production host matrix is established.
- The [host compatibility and validation matrix](../docs/validation/compatibility-matrix.md), [sanitized validation record template](../docs/validation/record-template.md), and [unreleased release notes](../docs/release-notes.md) track the gap between implemented code and validated deployment support.
- Issue #4 and #52 are closed; the remaining aggregate/management features are described in the [feature catalog](../docs/features/catalog.md). User-supplied Redis commands remain unsupported.
- Application connection guides document values and examples; ORM does not configure application files. A general in-panel updater is not implemented; see the [update lifecycle guide](../docs/guides/update-lifecycle.md).
