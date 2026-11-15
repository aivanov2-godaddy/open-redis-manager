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
