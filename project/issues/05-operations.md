# Add backup, restore and bounded monitoring

## Goal
Build account-safe backups and useful operational visibility.

## Acceptance criteria
- Users can create and list own-account snapshots subject to retention.
- Restore creates a safety snapshot and verifies the resulting service state.
- WHM can request a fleet operation and report per-account results.
- Metrics include memory, peak, connections, uptime, operations and hit/miss ratio.
- Last-known metrics remain visible with a stale marker when sampling fails.
- Exported diagnostics are previewable and credential-redacted.

## Progress

- The installed cPanel page requests bounded metrics for every configured account. The broker returns the fixed numeric allowlist, capture time and stale marker; it atomically retains one root-owned `0600` sample for up to 30 days and falls back to it when stopped or when probing fails. Account-scoped RDB snapshot creation, listing, download, three-snapshot retention, and restore with a validated safety snapshot and startup rollback attempt are implemented. Metric history, diagnostics export, WHM fleet backup/restore, and disposable-host validation remain open.
