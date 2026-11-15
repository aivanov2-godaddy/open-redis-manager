# Add account-isolated Redis and Valkey service adapter

## Goal
Create a backend interface for detection, provision, lifecycle, configuration, metrics and per-account migration.

## Acceptance criteria
- Detect binaries, service units and versions for supported Redis/Valkey packages.
- New-instance backend selection follows explicit WHM policy and host support.
- Upgrade preserves existing backend, port, credentials and data.
- Every service/config path is derived from trusted account metadata.
- No request data is interpolated into a shell command.
- Migration is explicit, snapshot-backed, verified, and rolls back on failure.
