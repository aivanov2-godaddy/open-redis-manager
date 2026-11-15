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

## Pull request plan

Open a feature branch and pull request for each coherent implementation increment after the corresponding issue is created. The first PR should deliver the prototype, docs, and UX screenshots; later PRs should ship one privileged boundary at a time. PRs require actual validation on the stated runtime and must disclose any screen that remains mock data.

## Current status

- Upstream repository: public; it was empty when this work started.
- Local repository: `main` and `origin` now target the repo; implementation is prepared on `codex/orm-foundation`.
- GitHub: milestone #1 and issues #1–#7 are created.
- PR: the initial foundation PR is being opened as a draft.
