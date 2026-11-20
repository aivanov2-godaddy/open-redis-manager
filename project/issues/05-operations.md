# Add backup, restore and bounded monitoring

## Goal
Build account-safe backups and useful operational visibility.

## Acceptance criteria
- Users can create and list own-account snapshots subject to retention.
- Restore creates a safety snapshot and verifies the resulting service state.
- WHM can request a fleet operation and report per-account results.
- Metrics include memory, peak, connections, uptime, operations and hit/miss ratio.
- Hourly history can be viewed over 24 hours and 7 days with bounded retention.
- Last-known metrics remain visible with a stale marker when sampling fails.
- Exported diagnostics are previewable and credential-redacted, and the account can explicitly download the report.

## Progress

- The installed cPanel page requests bounded metrics for every configured account. The broker returns the fixed numeric allowlist, capture time and stale marker; it atomically retains the latest root-owned `0600` sample and hourly history, with provider-configured retention for new instances (7–90 days), hard limits of 2,160 samples and 1 MiB, and 24-hour/7-day cPanel charts. Legacy instances retain 30-day history behavior. Account-scoped RDB snapshot creation, listing, download, three-snapshot retention, and restore with a validated safety snapshot and startup rollback attempt are implemented. The authenticated cPanel page also previews and downloads a minimal in-memory diagnostics JSON report that excludes identity, paths, credentials, key/value data, app payloads, sessions, logs, and command output. WHM now exposes per-account retained snapshots, create and restore actions with individual results; disposable-host validation remains open.
