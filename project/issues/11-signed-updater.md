# Implement a signed, versioned WHM updater

Live issue: [#70](https://github.com/aivanov2-godaddy/open-redis-manager/issues/70), milestone 0.2.0.

The initial signed file-update flow shipped in PRs #80–#92. It verifies signed release metadata and archives, previews v3 installed-file targets, requires explicit WHM confirmation, applies conflict-free file-only releases asynchronously, records bounded job state, and retains transaction recovery material. See the [update lifecycle guide](../../docs/guides/update-lifecycle.md).

Remaining acceptance:

- Preview migration actions and implement any required ORM state migrations transactionally, or document a reviewed no-migration release contract.
- Verify the installed package version and managed file manifest after apply; complete WHM registration and service-health verification for supported release types.
- Define and document production release signing, key rotation and artifact staging; updates currently use a locally pinned key and manually staged bundle.
- Add failure-injection coverage for interruption and recovery, and validate update lifecycle on a source-matched disposable cPanel host. Issue #7 tracks the overall compatibility and lifecycle gate.
- Do not claim host support without disposable validation.
